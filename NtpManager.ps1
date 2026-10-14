#Requires -Version 2.0
<#
    NtpManager.ps1 - версия 1.5
    ---------------------------------------------------------------------------
    Портативная утилита для Windows 7 / Windows Server 2008 R2 и новее (включая Windows 10/11
    и Windows Server 2012–2025): мониторинг и управление службой времени Windows (w32time), в которой эта
    машина одновременно:

      * NTP-СЕРВЕР  - отдаёт время клиентам в локальной сети (провайдер NtpServer);
      * NTP-КЛИЕНТ  - берёт время у сервера GPS в локальной сети без интернета
                      (провайдер NtpClient, Parameters\Type = NTP).

    Установка НЕ требуется: это скрипт PowerShell + .cmd-запускатор, которые можно
    положить в любую папку (в том числе на флешку) и запустить двойным щелчком.

    ВАЖНО ПРО КОДИРОВКУ: файл сохранён в UTF-8 с BOM. PowerShell 2.0 читает .ps1
    без BOM как ANSI и портит русские буквы - при пересохранении файла сохраняйте
    UTF-8 с BOM.

    РЕЖИМЫ ЗАПУСКА
      NtpManager.cmd [-Language ru|en]
          Графический интерфейс (значок, окно, журнал, автоподъём прав).
          Язык интерфейса (русский/английский) выбирается переключателем в самом окне
          или ключом -Language; по умолчанию берётся язык системы.

      NtpManager.cmd -Report
          Текстовая проверка состояния без прав администратора. Ничего не меняет.
          Код возврата: 0 - всё в норме, 1 - предупреждения, 2 - ошибки.
          Годится для запуска по расписанию и для мониторинга.

      NtpManager.cmd -Apply [-ServerList "192.168.1.50,0x9"] [-PollInterval 300]
                            [-EnableServer] [-DisableServer] [-EnableClient]
                            [-DisableClient] [-TimeSourceType NTP] [-Reliable]
                            [-NotReliable] [-OpenFirewall] [-RemoveFirewall]
                            [-MaxAllowedPhaseOffset 3600] [-StartupMode Auto]
                            [-NoRestart]
          Применение настроек из командной строки (требуются права администратора).
          Перед изменением автоматически создаётся резервная копия ветви реестра
          W32Time в папке NtpManager-backup.

      NtpManager.cmd -RestoreService
          Зарегистрировать службу времени заново (w32tm /register): нужно, когда
          её нет в списке служб (после w32tm /unregister или удаления ключа).

      NtpManager.cmd -Help
          Справка по ключам.

    ЧТО МЕНЯЕТСЯ В СИСТЕМЕ (только по явной команде пользователя)
      HKLM\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpServer\Enabled
      HKLM\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpClient\Enabled
      HKLM\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpClient\SpecialPollInterval
      HKLM\SYSTEM\CurrentControlSet\Services\W32Time\Parameters\Type
      HKLM\SYSTEM\CurrentControlSet\Services\W32Time\Parameters\NtpServer
      HKLM\SYSTEM\CurrentControlSet\Services\W32Time\Config\AnnounceFlags
      (дополнительно, если задано) Config\MaxAllowedPhaseOffset, Config\EventLogFlags
      (дополнительно) правило брандмауэра "NTP Server UDP 123 (NtpManager)"
      (дополнительно, если включена галочка «Записывать параметры и в ветвь политики»)
      HKLM\SOFTWARE\Policies\Microsoft\W32Time\Config | Parameters | TimeProviders

    Автор скрипта не несёт ответственности за последствия применения настроек:
    перед использованием на боевом сервере проверьте на тестовом. Все изменения
    обратимы резервной копией реестра (кнопка «Импорт из резервной копии»).
#>

[CmdletBinding()]
param(
    [switch]$Report,
    [switch]$Apply,
    [switch]$Help,

    [string]$ServerList = '',
    [string]$TimeSourceType = '',
    [int]$PollInterval = 0,
    [string]$StartupMode = '',
    [switch]$EnableServer,
    [switch]$DisableServer,
    [switch]$EnableClient,
    [switch]$DisableClient,
    [switch]$Reliable,
    [switch]$NotReliable,
    [switch]$OpenFirewall,
    [switch]$RemoveFirewall,
    [int]$MaxAllowedPhaseOffset = -1,
    [int]$EventLogFlags = -1,
    [switch]$NoRestart,
    [switch]$RestoreService,
    [switch]$UsePolicyBranch,
    [string]$Language = '',
    [string]$LogFile = '',
    [string]$ReportFile = ''
)

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# Общие переменные
# ---------------------------------------------------------------------------
$script:Ver        = '1.5'
$script:SvcName    = 'w32time'
$script:RegRoot    = 'SYSTEM\CurrentControlSet\Services\W32Time'
$script:FwRuleName = 'NTP Server UDP 123 (NtpManager)'
$script:NtpPort    = 123
$script:Ui         = @{}
$script:LogBoxMax  = 400        # сколько строк держать в окне журнала
$script:LogWrites  = 0
$script:SlowCache  = @{}        # кеш «медленных» проверок: брандмауэр, события, порт 123
$script:SntpStackOk = $null
$script:SntpStackError = ''
$script:EventsFallbackUntil = $null
$script:DomainInfo = $null
$script:Lang = 'ru'          # текущий язык интерфейса: 'ru' или 'en'
$script:LangUiLoading = $false

# Определение языка: ключ командной строки, затем ini, затем язык системы.
function Initialize-Language {
    param([string]$Requested = '')
    $code = $Requested
    if ($code -ne 'ru' -and $code -ne 'en') {
        $s = Get-Settings
        $code = [string]$s['Language']
    }
    if ($code -ne 'ru' -and $code -ne 'en') { $code = Get-SystemLanguage }
    $script:Lang = $code
}

# ---------------------------------------------------------------------------
# Локализация интерфейса. Язык хранится в ini (ключ Language), при первом запуске
# выбирается по языку системы: русская Windows - русский, иначе английский.
# Строки переводятся по словарю: сначала точное совпадение, затем - для составных
# строк состояния, отчётов и журнала - замена отдельных фрагментов.
# ---------------------------------------------------------------------------
function Get-SystemLanguage {
    try {
        $ui = [System.Globalization.CultureInfo]::CurrentUICulture
        if ($ui -ne $null -and $ui.TwoLetterISOLanguageName -eq 'ru') { return 'ru' }
    } catch { }
    return 'en'
}

$script:EnUi = @{
    'Обновить (F5)' = 'Refresh (F5)'
    'Проверить NTP' = 'Check NTP'
    'Разрешить UDP 123' = 'Allow UDP 123'
    'Текстовый отчёт' = 'Text report'
    'Справка' = 'Help'
    'Язык:' = 'Language:'
    'Итог: ещё не проверялось' = 'Summary: not checked yet'
    'Открыть журнал' = 'Open log'
    'Открыть папку' = 'Open folder'
    'Очистить' = 'Clear'
    'Состояние' = 'Status'
    'Служба' = 'Service'
    'Настройка' = 'Settings'
    'Диагностика' = 'Diagnostics'
    'Служба времени Windows (w32time)' = 'Windows Time service (w32time)'
    'Отображаемое имя:' = 'Display name:'
    'Состояние:' = 'Status:'
    'Тип запуска:' = 'Startup type:'
    'PID и учётная запись:' = 'PID and account:'
    'Запустить' = 'Start'
    'Остановить' = 'Stop'
    'Перезапустить' = 'Restart'
    'Восстановить службу времени' = 'Restore the time service'
    'Автозапуск при включении сервера' = 'Startup at boot'
    'Применить' = 'Apply'
    'Для сервера времени правильный выбор — «Автоматически».' = 'A time server should use Automatic.'
    'Мониторинг (пока окно открыто)' = 'Monitoring (while the window is open)'
    'Автообновление состояния каждые' = 'Auto-refresh every'
    'секунд' = 'seconds'
    'Уведомлять при изменении состояния службы (всплывающее уведомление)' = 'Notify when the service state changes (balloon tip)'
    'Проверять отклик NTP-сервера по таймеру (раз в 5 минут)' = 'Poll the NTP server on a timer (every 5 minutes)'
    'Показывать значок в области уведомлений' = 'Show a tray icon'
    'При закрытии окна сворачивать в область уведомлений, а не завершать' = 'Minimise to the tray instead of exiting on close'
    'Считать нормой раздачу времени клиентам (контролировать NTP-сервер)' = 'Expect this machine to serve time (monitor the NTP server)'
    'Считать нормой получение времени от GPS (контролировать NTP-клиент)' = 'Expect time to come from GPS (monitor the NTP client)'
    'Внимание: остановка службы времени на контроллере домена может временно нарушить работу Kerberos.' = 'Caution: stopping the time service on a domain controller can temporarily break Kerberos.'
    'Групповая политика службы времени (её значения важнее реестра службы)' = 'Time service group policy (its values override the service registry)'
    'Записывать параметры и в ветвь политики (SOFTWARE\Policies\Microsoft\W32Time)' = 'Also write the settings to the policy branch (SOFTWARE\Policies\Microsoft\W32Time)'
    'Открыть gpedit' = 'Open gpedit'
    'Удалить ветвь политики...' = 'Delete the policy branch...'
    'NTP-сервер: эта машина отдаёт время клиентам локальной сети' = 'NTP server: this machine serves time to LAN clients'
    'Включить провайдер NtpServer (слушать входящие NTP-запросы)' = 'Enable the NtpServer provider (listen for incoming NTP requests)'
    'Разрешить нестандартные комбинации режимов (лучшая совместимость клиентов)' = 'Allow non-standard mode combinations (better client compatibility)'
    'Помечать машину надёжным источником времени (AnnounceFlags = 5)' = 'Mark the machine as a reliable time source (AnnounceFlags = 5)'
    'NTP-клиент: получать время от GPS-сервера в локальной сети' = 'NTP client: obtain time from a GPS server on the LAN'
    'Включить провайдер NtpClient (получать время)' = 'Enable the NtpClient provider (obtain time)'
    'Тип источника времени:' = 'Time source type:'
    'Ручной список серверов (NTP) — рекомендуемый вариант' = 'Manual peer list (NTP) — recommended'
    'Иерархия домена (NT5DS)' = 'Domain hierarchy (NT5DS)'
    'Не синхронизировать (NoSync)' = 'Do not synchronise (NoSync)'
    'Адрес GPS-сервера времени — можно просто IP (например, 192.168.1.50):' = 'GPS time server address — an IP address is enough (for example 192.168.1.50):'
    'дописывать флаг ,0x9 самому' = 'append the ,0x9 flag automatically'
    'Интервал опроса, с:' = 'Poll interval, s:'
    'Прочее (необязательные параметры — оставьте поля пустыми, если не уверены)' = 'Other (optional settings — leave the fields blank if unsure)'
    'Тип запуска службы:' = 'Service startup type:'
    'Разрешить входящий UDP 123 в брандмауэре Windows' = 'Allow inbound UDP 123 in the Windows firewall'
    'Макс. разовое смещение часов, с:' = 'Max single clock offset, s:'
    'пусто — не менять; обычно 300, при сильно ушедших часах 3600' = 'blank — do not change; usually 300, or 3600 for a badly drifted clock'
    'пусто — не менять; 0..3, подробнее журнал = 2' = 'blank — do not change; 0..3, more logging = 2'
    'Оба поля необязательны: пустое поле = «оставить как есть». Значения вводятся целыми числами.' = 'Both fields are optional: blank means "leave as is". Values must be whole numbers.'
    'Что будет изменено (предпросмотр перед применением)' = 'Changes to apply (preview before applying)'
    'Проверить изменения' = 'Preview changes'
    'ПРИМЕНИТЬ НАСТРОЙКИ' = 'APPLY SETTINGS'
    'Рекомендуемые значения' = 'Recommended values'
    'Сохранить настройки' = 'Save settings'
    'Импорт из копии...' = 'Import from backup...'
    'Проверка сервера времени SNTP-запросом (без прав администратора)' = 'Time server check with an SNTP query (administrator rights not needed)'
    'Адрес сервера (IP или имя):' = 'Server address (IP or name):'
    'Проверить этот сервер' = 'Check this server'
    'Проверить 127.0.0.1' = 'Check 127.0.0.1'
    'Стабильность: 5 замеров' = 'Stability: 5 samples'
    'Подсказка: чтобы проверить доступность сервера для клиентов, запустите такую же проверку с клиентской машины.' = 'Tip: to verify that clients can reach this server, run the same check from a client machine.'
    'Команды службы времени: верхний ряд только читает, нижние меняют состояние (нужны права администратора)' = 'Windows Time commands: the top row only reads, the rows below change state (administrator rights required)'
    'Состояние синхронизации' = 'Synchronisation status'
    'Действующие настройки' = 'Effective settings'
    'Источники времени' = 'Time sources'
    'Замеры с сервера (5)' = 'Samples from server (5)'
    'События службы' = 'Service events'
    'Синхронизировать сейчас' = 'Synchronise now'
    'Перечитать источники' = 'Rediscover sources'
    'Кто слушает порт 123' = 'Who listens on port 123'
    'Правило брандмауэра: показать' = 'Firewall rule: show'
    'Удалить правило' = 'Delete rule'
    'Это обёртки над w32tm: состояние = /query /status, настройки = /query /configuration, источники = /query /peers, замеры = /stripchart, синхронизировать = /resync.' = 'These are wrappers around w32tm: status = /query /status, settings = /query /configuration, sources = /query /peers, samples = /stripchart, synchronise = /resync.'
    'Сохранить в файл' = 'Save to file'
    'Копировать' = 'Copy'
    'Параметр' = 'Item'
    'Значение' = 'Value'
    'Оценка' = 'Verdict'
    'Показать окно' = 'Show window'
    'Выход' = 'Exit'
    'OK — норма, !! — замечание, XX — ошибка, «--» — справочно. Автообновление «лёгкое» (служба и реестр), полная проверка — по кнопке «Обновить» или раз в 10 минут.' = 'OK — fine, !! — warning, XX — error, "--" — information. The periodic refresh is lightweight (service and registry); a full check runs on Refresh or every 10 minutes.'
    'служба времени, NTP-сервер и NTP-клиент (Windows Server 2008 R2)' = 'Windows Time service, NTP server and NTP client'
    'Проверить состояние' = 'Check status'
    'Автоматически' = 'Automatic'
    'Вручную' = 'Manual'
    'Отключена' = 'Disabled'
}

$script:EnTips = @{
    'Строки состояния: OK — норма, !! — замечание, XX — ошибка, «--» — справочно. У строк, взятых из кеша, показано время, когда проверка выполнялась.' = 'Status rows: OK — fine, !! — warning, XX — error, "--" — information. Cached rows show the time when the check was actually run.'
    'Тип запуска службы времени. Для сервера времени нужен «Автоматически».' = 'Startup type of the Windows Time service. A time server should use Automatic.'
    'Периодически обновлять состояние. Обновление «лёгкое» — только служба и параметры реестра, без опроса серверов и чтения журнала, поэтому окно не подвисает.' = 'Periodically refresh the state. The refresh is lightweight — only the service and registry values, without polling servers or reading the event log — so the window does not freeze.'
    'Период автообновления в секундах (5–600). Полная проверка (брандмауэр, события, порт) выполняется автоматически раз в 10 минут или по кнопке «Обновить».' = 'Auto-refresh period in seconds (5–600). A full check (firewall, events, port) runs automatically every 10 minutes or when you press Refresh.'
    'Показывать всплывающее уведомление, если служба времени остановилась или запустилась.' = 'Show a balloon tip when the time service stops or starts.'
    'Раз в 5 минут опрашивать свой NTP-сервер и проверять, что он отвечает. Опрос занимает до 1–3 секунд и может кратковременно «подвесить» окно — поэтому по умолчанию выключено.' = 'Poll the local NTP server every 5 minutes to confirm that it answers. The probe takes 1–3 seconds and may briefly freeze the window, so it is disabled by default.'
    'Показывать значок в области уведомлений с текущим состоянием службы времени.' = 'Show a tray icon with the current state of the Windows Time service.'
    'При закрытии окна утилита останется в области уведомлений и продолжит мониторинг.' = 'When you close the window the utility stays in the notification area and keeps monitoring.'
    'Что считать нормой: если галочка снята, выключенная раздача времени не будет считаться ошибкой.' = 'What to treat as normal: with this box cleared, disabled time serving is not reported as an error.'
    'Что считать нормой: если галочка снята, отсутствие получения времени не будет считаться ошибкой.' = 'What to treat as normal: with this box cleared, not obtaining time is not reported as an error.'
    'Разрешает этому компьютеру отдавать время по NTP (встроенный провайдер NtpServer). Без этого клиенты локальной сети не получат время. Нужен открытый входящий UDP 123.' = 'Allows this computer to serve time over NTP (the built-in NtpServer provider). Without it LAN clients get no time. Inbound UDP 123 must be open.'
    'AllowNonstandardModeCombinations = 1: отвечать и тем клиентам, кто обращается не строго по RFC (старые системы, часть промышленных контроллеров, аппаратные часы). Обычно можно включить.' = 'AllowNonstandardModeCombinations = 1: also answer clients that do not follow the RFC strictly (legacy systems, some industrial controllers, hardware clocks). Usually safe to enable.'
    'Помечает компьютер надёжным источником времени (реестр Config\AnnounceFlags = 5; то же делает w32tm /config /reliable:yes). 10 — обычный участник домена.' = 'Marks the computer as a reliable time source (registry Config\AnnounceFlags = 5; the same as w32tm /config /reliable:yes). 10 means an ordinary domain member.'
    'Включает получение времени от указанного ниже сервера (провайдер NtpClient). Если выключить, компьютер будет только отдавать время.' = 'Enables obtaining time from the server below (the NtpClient provider). If disabled, the computer only serves time.'
    'Type = NTP: брать время из списка адресов ниже. Это нужный вариант для GPS-сервера в локальной сети.' = 'Type = NTP: take time from the peer list below. This is the right choice for a GPS server on the LAN.'
    'Type = NT5DS: брать время из иерархии Active Directory. Не подходит, если время должно идти от GPS.' = 'Type = NT5DS: take time from the Active Directory hierarchy. Not suitable when time must come from GPS.'
    'Type = NoSync: ни с кем не синхронизироваться. Часы будут «плыть» — только для отладки.' = 'Type = NoSync: do not synchronise at all. The clock will drift — for debugging only.'
    'Адрес GPS-сервера времени. Можно указать только IP — при включённой галочке утилита сама допишет ,0x9. Несколько адресов разделяются пробелом: 192.168.1.50,0x9 192.168.1.51,0x9' = 'GPS time server address. An IP address alone is enough: with the checkbox enabled the utility appends ,0x9 itself. Separate several peers with a space: 192.168.1.50,0x9 192.168.1.51,0x9'
    'Флаг 0x9 = 0x1 (использовать заданный интервал опроса) + 0x8 (режим клиента). Без флага служба опрашивает источник по своему расписанию (64–1024 с) и поле «Интервал опроса» не действует.' = 'The 0x9 flag = 0x1 (use the configured poll interval) + 0x8 (client mode). Without it the service polls the source on its own schedule (64–1024 s) and the poll interval field has no effect.'
    'SpecialPollInterval: как часто опрашивать GPS-сервер, секунды. В локальной сети достаточно 60–900; Microsoft рекомендует не больше 3600. Действует только при флаге 0x1/0x9 в адресе.' = 'SpecialPollInterval: how often to poll the GPS server, in seconds. 60–900 is enough on a LAN; Microsoft recommends no more than 3600. Only effective with the 0x1/0x9 flag in the address.'
    'Автоматически — служба времени стартует при загрузке сервера (так нужно для сервера времени). Вручную/Отключена — обычно только для отладки.' = 'Automatic starts the time service at boot (required for a time server). Manual/Disabled is normally only for debugging.'
    'Создаёт правило входящего UDP 123 в брандмауэре Windows («NTP Server UDP 123 (NtpManager)»). Без него клиенты не получат время, даже если служба работает.' = 'Creates an inbound UDP 123 rule in the Windows firewall ("NTP Server UDP 123 (NtpManager)"). Without it clients get no time even when the service runs.'
    'MaxAllowedPhaseOffset, секунды: если расхождение часов больше этого значения, служба не станет догонять время разом, а запишет ошибку. Пусто — не менять. По умолчанию 300; при сильно ушедших часах ставят 3600.' = 'MaxAllowedPhaseOffset, seconds: if the clock offset exceeds this value the service will not correct the time in one step but logs an error instead. Blank means leave unchanged. The default is 300; use 3600 for a badly drifted clock.'
    'EventLogFlags: подробность записей службы в журнале System. 0 — минимум, 1 — важные события, 2 — также изменения времени, 3 — подробно. Пусто — не менять; для диагностики 2–3.' = 'EventLogFlags: verbosity of Windows Time records in the System log. 0 — minimum, 1 — important events, 2 — also time changes, 3 — verbose. Blank means leave unchanged; use 2–3 for diagnostics.'
    'Точный список изменений, которые будут внесены. Кнопка «Проверить изменения» ничего не меняет в системе.' = 'The exact list of changes that will be applied. The Preview changes button changes nothing on the system.'
    'Адрес сервера для проверки. С клиентской машины укажите адрес этого сервера — так проверится сквозная доступность вместе с брандмауэром.' = 'Server address to check. From a client machine enter this server address — that tests end-to-end reachability including the firewall.'
    'Вывод команд и результаты проверок. Можно сохранить в файл или скопировать.' = 'Command output and check results. You can save them to a file or copy them.'
    'Журнал работы утилиты. Полный журнал — в файле NtpManager.log.' = 'The utility activity log. The full log is kept in NtpManager.log.'
    'w32tm /query /status — состояние синхронизации: текущий источник, время последней удачной синхронизации, смещение, stratum, уровень.' = 'w32tm /query /status — synchronisation state: current source, time of the last successful sync, offset, stratum, level.'
    'w32tm /query /configuration — действующие параметры службы (провайдеры, интервалы, пороги коррекции).' = 'w32tm /query /configuration — effective service settings (providers, intervals, correction thresholds).'
    'w32tm /query /peers — список источников времени и состояние каждого из них: отвечает ли и когда была удачная синхронизация.' = 'w32tm /query /peers — the list of time sources and the state of each: whether it answers and when it last synced successfully.'
    'w32tm /stripchart — 5 замеров подряд у указанного сервера. Значения d: (задержка) и o: (смещение часов) применяются для оценки качества связи с GPS.' = 'w32tm /stripchart — five consecutive samples from the specified server. The d: (delay) and o: (clock offset) values are used to judge the quality of the link to the GPS.'
    'Последние записи службы времени из журнала System: кто/когда синхронизировался, были ли ошибки.' = 'The latest Windows Time records from the System log: who synced and when, and whether there were errors.'
    'w32tm /resync — заставить службу синхронизироваться немедленно. Требует прав администратора. Если время уже верное, служба может ответить «синхронизация не нужна».' = 'w32tm /resync — force the service to synchronise immediately. Requires administrator rights. If the time is already correct the service may answer that no resync is needed.'
    'w32tm /resync /rediscover — заново найти источники времени и синхронизироваться сразу. Полезно после смены адреса GPS-сервера.' = 'w32tm /resync /rediscover — rediscover time sources and synchronise at once. Useful after changing the GPS server address.'
    'Показать, какой процесс/служба реально слушает UDP 123. Если это не служба времени, встроенный NTP-сервер не сможет отвечать клиентам.' = 'Show which process/service actually listens on UDP 123. If it is not the time service, the built-in NTP server cannot answer clients.'
    'Показать правило брандмауэра для входящего UDP 123, если оно создано (netsh advfirewall firewall show rule).' = 'Show the firewall rule for inbound UDP 123 if it exists (netsh advfirewall firewall show rule).'
    'Разрешить входящий UDP 123 в брандмауэре Windows — без этого клиенты локальной сети не получат время.' = 'Allow inbound UDP 123 in the Windows firewall — without it LAN clients get no time.'
    'Удалить созданное утилитой правило брандмауэра. Клиенты локальной сети могут перестать получать время.' = 'Delete the firewall rule created by the utility. LAN clients may stop receiving time.'
    'Зарегистрировать службу времени заново (w32tm /register). Нужно, когда службы нет в списке служб: её «снял с регистрации» кто-то командой w32tm /unregister или удалил ключ службы, и тогда её действительно не видно в services.msc. Перед выполнением создаётся резервная копия ветви службы.' = 'Re-register the time service (w32tm /register). Needed when the service is missing from the service list: someone removed the registration with w32tm /unregister or deleted the service key, so it really is absent from services.msc. A backup of the service registry branch is created first.'
    'Если служба времени управляется групповой политикой, её значения важнее реестра службы. С этой галочкой утилита запишет свои параметры и в ветвь политики (HKLM\SOFTWARE\Policies\Microsoft\W32Time) — тогда они подействуют. Если политика задана в gpedit, правильнее настраивать её там, а эту галочку не включать.' = 'If the time service is governed by group policy, those values override the service registry. With this box ticked the utility writes its settings to the policy branch as well (HKLM\SOFTWARE\Policies\Microsoft\W32Time), so they take effect. If the policy is configured in gpedit, it is better to change it there and leave this box cleared.'
    'Открыть редактор локальной групповой политики (gpedit.msc), раздел: Конфигурация компьютера → Административные шаблоны → Система → Служба времени Windows. На сервере без графической оболочки (Server Core) gpedit недоступен — настройте политику с другой машины или удалите ветвь политики.' = 'Open the Local Group Policy Editor (gpedit.msc): Computer Configuration → Administrative Templates → System → Windows Time Service. On Server Core there is no gpedit — configure the policy from another machine or delete the policy branch.'
    'Удалить ветвь HKLM\SOFTWARE\Policies\Microsoft\W32Time (с резервной копией в рег-файл). После этого параметры службы будут браться из обычных ключей. Важно: если политика реально включена в gpedit, её значения вернутся при обновлении политики — в этом случае переведите нужные пункты в «Не задано».' = 'Delete the HKLM\SOFTWARE\Policies\Microsoft\W32Time branch (backed up to a .reg file first). After that the service settings come from the normal keys. Important: if the policy is really enabled in gpedit, its values will return at the next policy refresh — in that case set the relevant items to "Not Configured".'
}
$script:EnDyn = @{}
$script:EnParts = @(
    @('ОШИБКА: ', 'ERROR: '),
    @('ВНИМАНИЕ: ', 'WARNING: '),
    @('ОК: ', 'OK: '),
    @('ОК (раздача выключена)', 'OK (serving disabled)'),
    @('ОК (не требуется)', 'OK (not required)'),
    @('ОК (брандмауэр выключен)', 'OK (firewall disabled)'),
    @('ИТОГ: ', 'SUMMARY: '),
    @('Всё в норме', 'Everything is fine'),
    @('Есть ошибки: ', 'Errors: '),
    @('Замечания: ', 'Warnings: '),
    @(', замечаний ', ', warnings '),
    @(', ошибок ', ', errors '),
    @('обновлено ', 'updated '),
    @('БЕЗ ПРАВ АДМИНИСТРАТОРА: только просмотр', 'WITHOUT ADMINISTRATOR RIGHTS: view only'),
    @('Код возврата: ', 'Exit code: '),
    @('(0 — всё в норме, 1 — замечания, 2 — ошибки)', '(0 — all fine, 1 — warnings, 2 — errors)'),
    @('ВНИМАНИЕ: попробуйте перезагрузить сервер или нажать «Восстановить службу времени» на вкладке «Служба»', 'WARNING: try rebooting the server or use "Restore the time service" on the Service tab'),
    @('именно поэтому её не видно в списке служб. Нажмите «Восстановить службу времени» на вкладке «Служба» (это w32tm /register)', 'which is why it is missing from the service list. Use "Restore the time service" on the Service tab (that runs w32tm /register)'),
    @('нет в менеджере служб, но ключ службы в реестре есть', 'absent from the service manager, but the service registry key exists'),
    @('не зарегистрирована в системе', 'is not registered on this system'),
    @('Используется резервная проверка через w32tm. Причина: ', 'The w32tm fallback check is used. Reason: '),
    @('Проверка встроенным SNTP-клиентом', 'Built-in SNTP client check'),
    @('Проверка синтаксиса', 'Syntax check'),
    @('недоступна в этом сеансе PowerShell', 'is unavailable in this PowerShell session'),
    @('Отклик 127.0.0.1:123', 'Response from 127.0.0.1:123'),
    @('Сервер времени ', 'Time server '),
    @('отвечает (резервная проверка w32tm), задержка ', 'answers (w32tm fallback check), delay '),
    @('смещение o: ', 'offset o: '),
    @('сервер отвечает, но сам не синхронизирован (LI=3 / stratum 16)', 'the server answers but is not synchronised itself (LI=3 / stratum 16)'),
    @('отвечает, но не синхронизирован (нет привязки к GPS)', 'answers but is not synchronised (no GPS reference)'),
    @('большое расхождение часов', 'the clock differs significantly'),
    @('нет ответа (проверено через w32tm /stripchart)', 'no answer (checked with w32tm /stripchart)'),
    @('нет ответа', 'no answer'),
    @('на порту 123 отвечает посторонний процесс', 'a foreign process answers on port 123'),
    @(', а не служба времени Windows — ответ мог дать он', ', not the Windows Time service — the answer may have come from it'),
    @('порт слушает посторонний процесс', 'a foreign process is listening on the port'),
    @('служба времени Windows не сможет принимать запросы. Остановите или удалите сторонний NTP-сервис либо не включайте раздачу времени средствами Windows', 'the Windows Time service cannot accept requests. Stop or remove the third-party NTP service, or do not serve time with Windows'),
    @('возможен конфликт за порт 123', 'possible conflict over port 123'),
    @('Так и должно быть: отдельного процесса w32time в системе нет — служба живёт в общем процессе-хосте. «svchost» в строке выше — это она и есть, конфликта нет.', 'This is expected: there is no separate w32time process — the service lives inside a shared host process. The "svchost" above is that service, so there is no conflict.'),
    @('внутри процесса svchost.exe', 'inside the svchost.exe process'),
    @('политик не найдено', 'no policies found'),
    @('эти значения заданы политикой и перекрывают реестр службы. Правьте политику (gpedit.msc → Административные шаблоны → Система → Служба времени Windows) или переведите её в «Не задано», иначе изменения утилиты будут отменены', 'these values are set by group policy and override the service registry. Edit the policy (gpedit.msc → Administrative Templates → System → Windows Time Service) or set it to Not Configured, otherwise the changes made here will be reverted'),
    @('параметры задаются напрямую и ничего их не перекрывает.', 'settings come from the registry and nothing overrides them.'),
    @('Машина не в домене', 'The machine is not in a domain'),
    @('Машина в домене', 'The machine is in a domain'),
    @(': политика может прийти только из локальной групповой политики.', ': the policy can only come from this machine local group policy.'),
    @(': политику может задать и контроллер домена.', ': a domain controller can also set the policy.'),
    @('нет записей в журнале System', 'no records in the System log'),
    @('не обнаружены', 'none found'),
    @('не требуется', 'not required'),
    @('не контролируется', 'not monitored'),
    @('не удалось проверить', 'could not be checked'),
    @('нужны права администратора', 'administrator rights are required'),
    @('брандмауэр включён, клиенты могут не получить время', 'the firewall is on, so clients may get no time'),
    @('есть: ', 'present: '),
    @('не найдено', 'not found'),
    @('никто не слушает', 'nobody is listening'),
    @('домен:', 'domain:'),
    @(', частный:', ', private:'),
    @(', общий:', ', public:'),
    @('справочно', 'information'),
    @('не задано', 'not set'),
    @('включено', 'enabled'),
    @('отключено', 'disabled'),
    @('включён', 'enabled'),
    @('отключён', 'disabled'),
    @('Работает', 'Running'),
    @('Остановлена', 'Stopped'),
    @('Запускается', 'Starting'),
    @('Останавливается', 'Stopping'),
    @('Приостановлена', 'Paused'),
    @('неизвестно', 'unknown'),
    @('Служба w32time', 'Service w32time'),
    @('Тип запуска службы', 'Service startup type'),
    @('Файл w32time.dll', 'File w32time.dll'),
    @('NTP-сервер (раздача времени)', 'NTP server (serving time)'),
    @('NTP-клиент (получение времени)', 'NTP client (obtaining time)'),
    @('Параметры\Type (источник)', 'Parameters\Type (time source)'),
    @('Список серверов времени', 'Peer list'),
    @('Интервал опроса (SpecialPollInterval)', 'Poll interval (SpecialPollInterval)'),
    @('AnnounceFlags (надёжность)', 'AnnounceFlags (reliability)'),
    @('Групповая политика службы времени', 'Time service group policy'),
    @('Порт UDP 123', 'Port UDP 123'),
    @('Брандмауэр (профили)', 'Firewall (profiles)'),
    @('Правило брандмауэра для UDP 123', 'Firewall rule for UDP 123'),
    @('Другие NTP-службы', 'Other NTP services'),
    @('Последнее событие W32Time', 'Latest W32Time event'),
    @('Как работает служба времени', 'How the time service works'),
    @('отчёт о состоянии', 'status report'),
    @('Компьютер : ', 'Computer  : '),
    @('Время     : ', 'Time      : '),
    @('ОС        : ', 'OS        : '),
    @('Права     : ', 'Rights    : '),
    @('Итог      : ', 'Summary   : '),
    @('обычный пользователь', 'regular user'),
    @('администратор', 'administrator'),
    @('Вывод w32tm', 'w32tm output'),
    @(', источник ', ', reference '),
    @(', смещение ', ', offset '),
    @(', задержка ', ', delay '),
    @(' мс', ' ms'),
    @('[проверено ', '[checked '),
    @('проверено (w32tm /stripchart)', 'checked with w32tm /stripchart'),
    @('ОК, источников: ', 'OK, sources: '),
    @('отвечает клиентам', 'answers clients'),
    @('ручной список серверов', 'manual peer list'),
    @('надёжный источник времени', 'reliable time source'),
    @('РЕКОМЕНДУЕТСЯ «Автоматически»', 'RECOMMENDED: Automatic'),
    @('клиенты не получат время', 'clients will get no time'),
    @('служба не работает', 'the service is not running'),
    @('машина не берёт время от GPS', 'the machine does not obtain time from GPS'),
    @('синхронизация отключена', 'synchronisation is disabled'),
    @('не указан GPS-сервер', 'no GPS server specified'),
    @('NTP-сервер не запущен фактически', 'the NTP server is not actually running'),
    @('ВНИМАНИЕ: будет использоваться 64–1024 с', 'WARNING: the default 64–1024 s will be used'),
    @('нестандартное значение', 'non-standard value'),
    @('обычно для сервера ставят 5', 'a time server usually uses 5'),
    @('включён, хотя не требуется', 'enabled although not required'),
    @('время берётся из иерархии домена, а не от GPS', 'time comes from the domain hierarchy instead of GPS'),
    @('ожидается NTP', 'NTP is expected'),
    @('часть старых/нестандартных клиентов не получит время', 'some legacy or non-compliant clients will get no time'),
    @('проверьте запись ', 'check the entry '),
    @('Сервер            : ', 'Server            : '),
    @('Версия/режим ответа: NTP v', 'Version/mode      : NTP v'),
    @('Идентификатор источника: ', 'Reference ID      : '),
    @('Время сервера UTC : ', 'Server time (UTC) : '),
    @('Смещение          : ', 'Offset            : '),
    @('Задержка обмена   : ', 'Round-trip delay  : '),
    @('Состояние         : ', 'State             : '),
    @('НЕТ ОТВЕТА от ', 'NO ANSWER from '),
    @('Что проверить: ', 'What to check: '),
    @('положительное = наши часы спешат', 'positive means our clock is ahead'),
    @('сервер не вернул метку времени', 'the server did not return a timestamp'),
    @('точный расчёт по 4 меткам', 'computed from all four timestamps'),
    @('приблизительно (сервер не вернул метки приёма/передачи)', 'approximate (the server returned no receive/transmit timestamps)'),
    @('сервер синхронизирован', 'the server is synchronised'),
    @(', замечаний: ', ', warnings: '),
    @(', ошибок: ', ', errors: '),
    @('(ок: ', '(ok: '),
    @('(ок ', '(ok '),
    @('= служба времени', '= the time service'),
    @('Автоматически', 'Automatic'),
    @('Вручную', 'Manual'),
    @('Отключена', 'Disabled'),
    @('ОК', 'OK')
)

function T {
    param([string]$Text)
    if ($Text -eq $null) { return $Text }
    if ($script:Lang -ne 'en') { return $Text }
    if ($script:EnUi.ContainsKey($Text)) { return $script:EnUi[$Text] }
    if ($script:EnTips.ContainsKey($Text)) { return $script:EnTips[$Text] }
    if ($script:EnDyn.ContainsKey($Text)) { return $script:EnDyn[$Text] }
    return $Text
}

# Перевод составных строк: перебираем фрагменты в заданном порядке.
function TPart {
    param([string]$Text)
    if ($Text -eq $null) { return $Text }
    if ($script:Lang -ne 'en') { return $Text }
    $out = [string]$Text
    foreach ($pair in $script:EnParts) {
        if ($out.IndexOf($pair[0]) -ge 0) { $out = $out.Replace($pair[0], $pair[1]) }
    }
    # Единицы измерения после числа: «300 с» -> «300 s» (безопасно, только сразу после цифры).
    $out = [regex]::Replace($out, '(?<=\d)\s+с\b', ' s')
    return $out
}

# Каталог, где лежит сам скрипт: сначала рядом со скриптом (портативность),
# если писать нельзя - во временную папку пользователя.
$script:ScriptFull = ''
try {
    if ($MyInvocation.MyCommand.Path) {
        $script:ScriptFull = [System.IO.Path]::GetFullPath($MyInvocation.MyCommand.Path)
    } elseif ($MyInvocation.MyCommand.Definition) {
        $script:ScriptFull = [System.IO.Path]::GetFullPath($MyInvocation.MyCommand.Definition)
    }
} catch {
    $script:ScriptFull = ''
}
if ($script:ScriptFull -ne '') {
    $script:ScriptDir = [System.IO.Path]::GetDirectoryName($script:ScriptFull)
} else {
    $script:ScriptDir = (Get-Location).Path
}

function Test-DirWritable {
    param([string]$Dir)
    if (-not $Dir) { return $false }
    try {
        if (-not [System.IO.Directory]::Exists($Dir)) { return $false }
        $probe = [System.IO.Path]::Combine($Dir, '.ntpmgr_' + [Guid]::NewGuid().ToString('N') + '.tmp')
        [System.IO.File]::WriteAllText($probe, 'x')
        [System.IO.File]::Delete($probe)
        return $true
    } catch {
        return $false
    }
}

if (Test-DirWritable $script:ScriptDir) {
    $script:WorkDir = $script:ScriptDir
} else {
    $script:WorkDir = [System.IO.Path]::Combine($env:TEMP, 'NtpManager')
    if (-not [System.IO.Directory]::Exists($script:WorkDir)) {
        try { [void][System.IO.Directory]::CreateDirectory($script:WorkDir) } catch { }
    }
}
$script:SettingsFile = [System.IO.Path]::Combine($script:WorkDir, 'NtpManager.settings.ini')
$script:BackupDir    = [System.IO.Path]::Combine($script:WorkDir, 'NtpManager-backup')
if (-not [System.IO.Directory]::Exists($script:BackupDir)) {
    try { [void][System.IO.Directory]::CreateDirectory($script:BackupDir) } catch { }
}
if ($LogFile -ne '') {
    $script:LogFile = $LogFile
} else {
    $script:LogFile = [System.IO.Path]::Combine($script:WorkDir, 'NtpManager.log')
}

# ---------------------------------------------------------------------------
# Права администратора
# ---------------------------------------------------------------------------
function Test-Admin {
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object System.Security.Principal.WindowsPrincipal($id)
        return $pr.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}
$script:IsAdmin = Test-Admin

# ---------------------------------------------------------------------------
# Вывод и журнал
# ---------------------------------------------------------------------------
function Write-Cli {
    param([string]$Text = '', [string]$Color = '')
    $Text = TPart $Text
    if ($Color -ne '') {
        Write-Host $Text -ForegroundColor $Color
    } else {
        Write-Host $Text
    }
}

function Write-LogToUi {
    param([string]$Line)
    if ($script:Ui -eq $null) { return }
    if (-not $script:Ui.ContainsKey('LogBox')) { return }
    $box = $script:Ui['LogBox']
    if ($box -eq $null) { return }
    try {
        $box.AppendText($Line + [Environment]::NewLine)
        if ($box.Lines.Length -gt $script:LogBoxMax) {
            $keep = $box.Lines[($box.Lines.Length - $script:LogBoxMax)..($box.Lines.Length - 1)]
            $box.Lines = $keep
        }
        $box.SelectionStart = $box.TextLength
        $box.ScrollToCaret()
    } catch { }
}

function Add-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $Message = TPart $Message
    $line = '{0} [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $script:LogWrites = $script:LogWrites + 1
    try {
        if ($script:LogWrites % 25 -eq 1) {
            if ([System.IO.File]::Exists($script:LogFile)) {
                $fi = New-Object System.IO.FileInfo($script:LogFile)
                if ($fi.Length -gt 2097152) {
                    $old = $script:LogFile + '.1'
                    if ([System.IO.File]::Exists($old)) { [System.IO.File]::Delete($old) }
                    [System.IO.File]::Move($script:LogFile, $old)
                }
            }
        }
        [System.IO.File]::AppendAllText($script:LogFile, $line + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
    Write-LogToUi $line
    if ($Level -eq 'ERROR') { Write-Cli $line 'Red' }
}

# ---------------------------------------------------------------------------
# Запуск внешних программ
# ---------------------------------------------------------------------------
function Invoke-Exe {
    param(
        [string]$FilePath,
        [string]$ArgumentString = '',
        [int]$TimeoutSec = 60
    )
    $res = New-Object PSObject -Property @{
        ExitCode = -1
        StdOut   = ''
        StdErr   = ''
        Error    = ''
        TimedOut = $false
    }
    if (-not [System.IO.File]::Exists($FilePath)) {
        $res.Error = 'Файл не найден: ' + $FilePath
        return $res
    }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $FilePath
        $psi.Arguments              = $ArgumentString
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.CreateNoWindow         = $true
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        [void]$proc.Start()
        # Выводы этих утилит малы (единицы КБ), поэтому синхронное чтение безопасно.
        $res.StdOut = $proc.StandardOutput.ReadToEnd()
        $res.StdErr = $proc.StandardError.ReadToEnd()
        if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
            $res.TimedOut = $true
            try { $proc.Kill() } catch { }
        } else {
            $res.ExitCode = $proc.ExitCode
        }
        try { $proc.Close() } catch { }
    } catch {
        $res.Error = $_.Exception.Message
    }
    return $res
}

function Get-ExeText {
    param($Result, [switch]$WithErrors)
    if ($Result -eq $null) { return '' }
    $parts = New-Object System.Collections.ArrayList
    if ($Result.StdOut) { [void]$parts.Add($Result.StdOut.TrimEnd()) }
    if ($WithErrors -and $Result.StdErr) { [void]$parts.Add($Result.StdErr.TrimEnd()) }
    if ($Result.Error) { [void]$parts.Add($Result.Error) }
    if ($parts.Count -eq 0) { return '' }
    return ($parts -join [Environment]::NewLine).TrimEnd()
}

function Get-ToolPath {
    param([string]$Name)
    return [System.IO.Path]::Combine($env:SystemRoot, 'System32\' + $Name)
}

function Invoke-W32tm {
    param([string]$Arguments = '/query /status', [int]$TimeoutSec = 90)
    return Invoke-Exe -FilePath (Get-ToolPath 'w32tm.exe') -ArgumentString $Arguments -TimeoutSec $TimeoutSec
}

# ---------------------------------------------------------------------------
# Реестр
# ---------------------------------------------------------------------------
function Get-RegKind {
    param([string]$Kind)
    switch ($Kind) {
        'DWord'        { return [Microsoft.Win32.RegistryValueKind]::DWord }
        'QWord'        { return [Microsoft.Win32.RegistryValueKind]::QWord }
        'Binary'       { return [Microsoft.Win32.RegistryValueKind]::Binary }
        'ExpandString' { return [Microsoft.Win32.RegistryValueKind]::ExpandString }
        'MultiString'  { return [Microsoft.Win32.RegistryValueKind]::MultiString }
        default        { return [Microsoft.Win32.RegistryValueKind]::String }
    }
}

function Get-RegValue {
    param([string]$SubKey, [string]$Name)
    $key = $null
    try {
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($SubKey, $false)
        if ($key -eq $null) { return $null }
        return $key.GetValue($Name, $null)
    } catch {
        return $null
    } finally {
        if ($key -ne $null) { try { $key.Close() } catch { } }
    }
}

function Test-RegKeyExists {
    param([string]$SubKey)
    $key = $null
    try {
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($SubKey, $false)
        if ($key -eq $null) { return $false }
        return $true
    } catch {
        return $false
    } finally {
        if ($key -ne $null) { try { $key.Close() } catch { } }
    }
}

function Ensure-RegKey {
    param([string]$SubKey)
    # Возвращает $true, если ключ пришлось создать.
    if (Test-RegKeyExists $SubKey) { return $false }
    $key = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey($SubKey)
    if ($key -eq $null) { throw ('Не удалось создать ключ реестра: HKLM\' + $SubKey) }
    $key.Close()
    return $true
}

function Set-RegValue {
    param([string]$SubKey, [string]$Name, $Value, [string]$Kind = 'DWord')
    $key = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey($SubKey)
    if ($key -eq $null) { throw ('Не удалось открыть ключ реестра для записи: HKLM\' + $SubKey) }
    try {
        $key.SetValue($Name, $Value, (Get-RegKind $Kind))
    } finally {
        $key.Close()
    }
}

function Remove-RegValue {
    param([string]$SubKey, [string]$Name)
    $key = $null
    try {
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($SubKey, $true)
        if ($key -eq $null) { return }
        if ($key.GetValue($Name, $null) -eq $null) { return }
        $key.DeleteValue($Name, $false)
    } finally {
        if ($key -ne $null) { try { $key.Close() } catch { } }
    }
}

# ---------------------------------------------------------------------------
# Служба w32time
# ---------------------------------------------------------------------------
function Convert-ServiceStateRu {
    param([string]$State)
    switch ($State) {
        'Running'      { return 'Работает' }
        'Stopped'      { return 'Остановлена' }
        'StartPending' { return 'Запускается' }
        'StopPending'  { return 'Останавливается' }
        'Paused'       { return 'Приостановлена' }
        ''             { return 'неизвестно' }
        default        { return $State }
    }
}

function Convert-StartModeRu {
    param([string]$Mode)
    switch ($Mode) {
        'Auto'      { return 'Автоматически' }
        'Automatic' { return 'Автоматически' }
        'Manual'    { return 'Вручную' }
        'Disabled'  { return 'Отключена' }
        ''          { return 'неизвестно' }
        default     { return $Mode }
    }
}

function Convert-BoolRu {
    param($Value)
    if ($Value -eq $null) { return 'не задано' }
    if ([int]$Value -ne 0) { return 'включено' } else { return 'отключено' }
}

function Get-MachineName {
    $n = ''
    try { $n = [string][System.Environment]::MachineName } catch { }
    if ($n -eq '') { try { $n = [string]$env:COMPUTERNAME } catch { } }
    if ($n -eq '') {
        try { $n = [string](Get-WmiObject Win32_ComputerSystem -ErrorAction SilentlyContinue).Name } catch { }
    }
    if ($n -eq '') { $n = 'неизвестно' }
    return $n
}

function Get-ServiceSnapshot {
    param([switch]$Fast)
    $snap = New-Object PSObject -Property @{
        Exists      = $false
        Status      = ''
        StatusRu    = ''
        StartMode   = ''
        StartModeRu = ''
        DisplayName = ''
        RegisteredInRegistry = $false
        ProcessId   = 0
        StartName   = ''
        PathName    = ''
    }
    $svc = $null
    try { $svc = Get-Service -Name $script:SvcName -ErrorAction SilentlyContinue } catch { $svc = $null }
    if ($svc -ne $null) {
        $snap.Exists      = $true
        $snap.Status      = [string]$svc.Status
        $snap.StatusRu    = Convert-ServiceStateRu ([string]$svc.Status)
        $snap.DisplayName = [string]$svc.DisplayName
    }
    # Есть ли служба в реестре (быстро, без WMI) — нужно для диагностики случая
    # «служба не отображается в списке служб».
    $snap.RegisteredInRegistry = Test-RegKeyExists ('SYSTEM\CurrentControlSet\Services\' + $script:SvcName)
    if ($Fast) {
        # «Быстрый» снимок для автообновления: без WMI, тип запуска - из реестра.
        $regStart = Get-RegValue ('SYSTEM\CurrentControlSet\Services\' + $script:SvcName) 'Start'
        if ($regStart -ne $null) {
            switch ([int]$regStart) {
                2       { $snap.StartMode = 'Auto';     $snap.StartModeRu = 'Автоматически' }
                3       { $snap.StartMode = 'Manual';   $snap.StartModeRu = 'Вручную' }
                4       { $snap.StartMode = 'Disabled'; $snap.StartModeRu = 'Отключена' }
                default { $snap.StartMode = '';         $snap.StartModeRu = 'неизвестно' }
            }
        }
        return $snap
    }
    $wmi = $null
    try {
        $wmi = Get-WmiObject Win32_Service -Filter ("Name='" + $script:SvcName + "'") -ErrorAction SilentlyContinue
    } catch { $wmi = $null }
    if ($wmi -ne $null) {
        $snap.StartMode   = [string]$wmi.StartMode
        $snap.StartModeRu = Convert-StartModeRu ([string]$wmi.StartMode)
        $snap.ProcessId   = [int]$wmi.ProcessId
        $snap.StartName   = [string]$wmi.StartName
        $snap.PathName    = [string]$wmi.PathName
    }
    return $snap
}

function Start-TimeService {
    param([int]$TimeoutSec = 40)
    try {
        Start-Service -Name $script:SvcName -ErrorAction Stop
    } catch {
        return $_.Exception.Message
    }
    $waited = 0
    while ($waited -lt ($TimeoutSec * 2)) {
        $s = Get-Service -Name $script:SvcName -ErrorAction SilentlyContinue
        if ($s -ne $null -and [string]$s.Status -eq 'Running') { return '' }
        Start-Sleep -Milliseconds 500
        $waited = $waited + 1
    }
    return 'Служба не перешла в состояние «Работает» за отведённое время'
}

function Stop-TimeService {
    param([int]$TimeoutSec = 40)
    $err = ''
    try {
        Stop-Service -Name $script:SvcName -Force -ErrorAction Stop
    } catch {
        $err = $_.Exception.Message
        $r = Invoke-Exe -FilePath (Get-ToolPath 'sc.exe') -ArgumentString ('stop ' + $script:SvcName) -TimeoutSec 40
        if ($r.ExitCode -ne 0) { return $err }
    }
    $waited = 0
    while ($waited -lt ($TimeoutSec * 2)) {
        $s = Get-Service -Name $script:SvcName -ErrorAction SilentlyContinue
        if ($s -eq $null) { return '' }
        if ([string]$s.Status -eq 'Stopped') { return '' }
        Start-Sleep -Milliseconds 500
        $waited = $waited + 1
    }
    if ($err -ne '') { return $err }
    return 'Служба не перешла в состояние «Остановлена» за отведённое время'
}

function Restart-TimeService {
    param([int]$TimeoutSec = 40)
    $e1 = Stop-TimeService -TimeoutSec $TimeoutSec
    if ($e1 -ne '') { return 'Остановка: ' + $e1 }
    $e2 = Start-TimeService -TimeoutSec $TimeoutSec
    if ($e2 -ne '') { return 'Запуск: ' + $e2 }
    return ''
}

function Set-TimeServiceStartupMode {
    param([string]$Mode)   # Automatic | Manual | Disabled
    $value = ''
    switch ($Mode) {
        'Automatic' { $value = 'auto' }
        'Auto'      { $value = 'auto' }
        'auto'      { $value = 'auto' }
        'Manual'    { $value = 'demand' }
        'demand'    { $value = 'demand' }
        'Disabled'  { $value = 'disabled' }
        'disabled'  { $value = 'disabled' }
        default     { throw ('Неизвестный тип запуска: ' + $Mode) }
    }
    # sc.exe требует пробел после знака равенства: "start= auto"
    $r = Invoke-Exe -FilePath (Get-ToolPath 'sc.exe') -ArgumentString ('config ' + $script:SvcName + ' start= ' + $value) -TimeoutSec 40
    if ($r.ExitCode -ne 0) {
        return ('sc.exe config вернул код ' + $r.ExitCode + ': ' + (Get-ExeText $r -WithErrors))
    }
    return ''
}

# ---------------------------------------------------------------------------
# Текущее состояние настроек NTP (реестр)
# ---------------------------------------------------------------------------
function Get-NtpConfigState {
    $root = $script:RegRoot
    $st = New-Object PSObject -Property @{
        ServerEnabled      = $null
        ClientEnabled      = $null
        AllowNonstandard   = $null
        Type               = $null
        Peers              = $null
        AnnounceFlags      = $null
        SpecialPollInterval = $null
        SpecialPollTimeRemaining = $null
        MaxAllowedPhaseOffset    = $null
        EventLogFlags      = $null
        LocalClockDispersion = $null
        W32TimeDllExists   = $false
        NtpServerKeyExists = $false
        NtpClientKeyExists = $false
        ParamsKeyExists    = $false
    }
    $st.NtpServerKeyExists = Test-RegKeyExists ($root + '\TimeProviders\NtpServer')
    $st.NtpClientKeyExists = Test-RegKeyExists ($root + '\TimeProviders\NtpClient')
    $st.ParamsKeyExists    = Test-RegKeyExists ($root + '\Parameters')

    $st.ServerEnabled       = Get-RegValue ($root + '\TimeProviders\NtpServer') 'Enabled'
    $st.AllowNonstandard    = Get-RegValue ($root + '\TimeProviders\NtpServer') 'AllowNonstandardModeCombinations'
    $st.ClientEnabled       = Get-RegValue ($root + '\TimeProviders\NtpClient') 'Enabled'
    $st.SpecialPollInterval = Get-RegValue ($root + '\TimeProviders\NtpClient') 'SpecialPollInterval'
    $st.SpecialPollTimeRemaining = Get-RegValue ($root + '\TimeProviders\NtpClient') 'SpecialPollTimeRemaining'
    $st.Type                = Get-RegValue ($root + '\Parameters') 'Type'
    $st.Peers               = Get-RegValue ($root + '\Parameters') 'NtpServer'
    $st.AnnounceFlags       = Get-RegValue ($root + '\Config') 'AnnounceFlags'
    $st.MaxAllowedPhaseOffset = Get-RegValue ($root + '\Config') 'MaxAllowedPhaseOffset'
    $st.EventLogFlags       = Get-RegValue ($root + '\Config') 'EventLogFlags'
    $st.LocalClockDispersion = Get-RegValue ($root + '\Config') 'LocalClockDispersion'

    $dll = [System.IO.Path]::Combine($env:SystemRoot, 'System32\w32time.dll')
    $st.W32TimeDllExists = [System.IO.File]::Exists($dll)
    return $st
}

# Список пиров в формате w32tm: "сервер1,0x9 сервер2,0x9" (разделитель - пробел).
# Принимаем также разделители-запятые и точки с запятой: "a,0x9; b" -> "a,0x9 b".
function Get-PeerListNormalized {
    param([string]$Raw)
    $result = New-Object System.Collections.ArrayList
    if (-not $Raw) { return '' }
    $clean = $Raw -replace ';', ' '
    $clean = $clean -replace "`r", ' ' -replace "`n", ' ' -replace "`t", ' '
    $tokens = $clean.Split(' ')
    foreach ($token in $tokens) {
        $t = $token.Trim()
        if ($t -eq '') { continue }
        $parts = $t.Split(',')
        if ($parts.Length -ge 2 -and $parts[1] -match '^(0x[0-9a-fA-F]{1,2}|[0-9]{1,2})$') {
            [void]$result.Add($parts[0] + ',' + $parts[1])
            for ($i = 2; $i -lt $parts.Length; $i++) {
                if ($parts[$i].Trim() -ne '') { [void]$result.Add($parts[$i].Trim()) }
            }
        } else {
            foreach ($p in $parts) {
                if ($p.Trim() -ne '') { [void]$result.Add($p.Trim()) }
            }
        }
    }
    if ($result.Count -eq 0) { return '' }
    return ($result -join ' ')
}

function Get-PeerHostsOnly {
    param([string]$Raw)
    $norm = Get-PeerListNormalized $Raw
    if ($norm -eq '') { return @() }
    $out = New-Object System.Collections.ArrayList
    foreach ($p in $norm.Split(' ')) {
        if ($p -eq '') { continue }
        $host_ = ($p.Split(','))[0]
        [void]$out.Add($host_)
    }
    return $out.ToArray()
}

# Если у адреса не указан флаг, дописываем 0x9 (клиент + использовать заданный интервал опроса).
# Благодаря этому в поле достаточно ввести только IP-адрес GPS-сервера.
function Add-DefaultPeerFlags {
    param([string]$List, [string]$Flags = '0x9')
    $norm = Get-PeerListNormalized $List
    if ($norm -eq '') { return '' }
    $out = New-Object System.Collections.ArrayList
    foreach ($p in $norm.Split(' ')) {
        if ($p -eq '') { continue }
        if ($p.IndexOf(',') -ge 0) { [void]$out.Add($p) }
        else { [void]$out.Add($p + ',' + $Flags) }
    }
    return ($out -join ' ')
}

# ---------------------------------------------------------------------------
# Брандмауэр Windows
# ---------------------------------------------------------------------------
function Get-FirewallProfilesEnabled {
    $res = New-Object PSObject -Property @{
        DomainProfile   = $null
        StandardProfile = $null
        PublicProfile   = $null
        AnyEnabled      = $false
    }
    $base = 'SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy'
    foreach ($p in @('DomainProfile', 'StandardProfile', 'PublicProfile')) {
        $v = Get-RegValue ($base + '\' + $p) 'EnableFirewall'
        if ($v -ne $null) { $res.$p = [int]$v }
    }
    if (($res.DomainProfile -eq 1) -or ($res.StandardProfile -eq 1) -or ($res.PublicProfile -eq 1)) {
        $res.AnyEnabled = $true
    }
    return $res
}

function Get-NtpFirewallRuleInfo {
    $info = New-Object PSObject -Property @{ Checked = $true; Exists = $false; Text = '' }
    $r = Invoke-Exe -FilePath (Get-ToolPath 'netsh.exe') -ArgumentString ('advfirewall firewall show rule name="' + $script:FwRuleName + '"') -TimeoutSec 40
    if ($r.Error -ne '' -or $r.TimedOut) { $info.Checked = $false }
    if ($r.ExitCode -eq 0) { $info.Exists = $true }
    $info.Text = Get-ExeText $r -WithErrors
    return $info
}

function Add-NtpFirewallRule {
    $args_ = 'advfirewall firewall add rule name="' + $script:FwRuleName + '" dir=in action=allow protocol=UDP localport=' + $script:NtpPort + ' profile=any enable=yes'
    return Invoke-Exe -FilePath (Get-ToolPath 'netsh.exe') -ArgumentString $args_ -TimeoutSec 40
}

function Remove-NtpFirewallRule {
    $args_ = 'advfirewall firewall delete rule name="' + $script:FwRuleName + '" dir=in protocol=UDP localport=' + $script:NtpPort
    return Invoke-Exe -FilePath (Get-ToolPath 'netsh.exe') -ArgumentString $args_ -TimeoutSec 40
}

# Какие службы работают внутри указанного процесса. Нужно потому, что служба времени
# живёт внутри общего процесса svchost.exe: определять владельца порта 123 по имени
# процесса нельзя — только по PID службы или по составу служб внутри процесса.
function Get-ServicesInProcess {
    param([int]$ProcessId, [int]$CacheSeconds = 30)
    $key = 'SvcInProc_' + $ProcessId
    $cached = $script:SlowCache[$key]
    if ($cached -ne $null) {
        if (((Get-Date) - [datetime]$cached.Time).TotalSeconds -lt $CacheSeconds) { return $cached.Names }
    }
    $names = New-Object System.Collections.ArrayList
    try {
        $svcs = Get-WmiObject Win32_Service -Filter ("ProcessId=" + $ProcessId) -ErrorAction SilentlyContinue
        foreach ($s in @($svcs)) {
            if ($s -eq $null) { continue }
            $nm = [string]$s.Name
            if ($nm -ne '') { [void]$names.Add($nm) }
        }
    } catch { }
    $o = New-Object PSObject -Property @{ Time = (Get-Date); Names = $names.ToArray() }
    $script:SlowCache[$key] = $o
    return $o.Names
}

# ---------------------------------------------------------------------------
# Слушатели UDP-порта 123 (кто именно слушает)
# ---------------------------------------------------------------------------
function Get-UdpListeners {
    param([int]$Port = 123)
    $items = New-Object System.Collections.ArrayList
    $r = Invoke-Exe -FilePath (Get-ToolPath 'netstat.exe') -ArgumentString ('-ano -p udp') -TimeoutSec 60
    if ($r.StdOut -eq '') { return $items }
    foreach ($line in ($r.StdOut -split "`r?`n")) {
        if ($line -match '^\s*UDP\s+(\S+):(\d+)\s+\S*\s+(\d+)\s*$') {
            $p = [int]$Matches[2]
            if ($p -ne $Port) { continue }
            $item = New-Object PSObject -Property @{
                Address   = $Matches[1]
                Port      = $p
                ProcessId = [int]$Matches[3]
                Process   = ''
                OwnedByW32Time = $false
            }
            [void]$items.Add($item)
        }
    }
    foreach ($it in $items) {
        try {
            $proc = Get-Process -Id $it.ProcessId -ErrorAction SilentlyContinue
            if ($proc -ne $null) { $it.Process = [string]$proc.ProcessName }
        } catch { }
    }
    return $items
}

# ---------------------------------------------------------------------------
# Резервное копирование / восстановление настроек
# ---------------------------------------------------------------------------
function Backup-W32TimeRegistry {
    $reg = Get-ToolPath 'reg.exe'
    $name = 'W32Time_' + (Get-Date).ToString('yyyyMMdd_HHmmss') + '.reg'
    $path = [System.IO.Path]::Combine($script:BackupDir, $name)
    $arg = 'export "HKLM\' + $script:RegRoot + '" "' + $path + '" /y'
    $r = Invoke-Exe -FilePath $reg -ArgumentString $arg -TimeoutSec 60
    if ($r.ExitCode -eq 0 -and [System.IO.File]::Exists($path)) {
        Add-Log ('Создана резервная копия настроек: ' + $path)
        return $path
    }
    Add-Log ('Не удалось создать резервную копию: ' + (Get-ExeText $r -WithErrors)) 'ERROR'
    return ''
}

function Restore-W32TimeRegistry {
    param([string]$RegFile)
    if (-not (Test-Path -LiteralPath $RegFile)) { return 'Файл не найден: ' + $RegFile }
    $reg = Get-ToolPath 'reg.exe'
    $r = Invoke-Exe -FilePath $reg -ArgumentString ('import "' + $RegFile + '"') -TimeoutSec 60
    if ($r.ExitCode -ne 0) { return (Get-ExeText $r -WithErrors) }
    return ''
}

function Get-BackupFiles {
    $items = New-Object System.Collections.ArrayList
    if (-not [System.IO.Directory]::Exists($script:BackupDir)) { return $items }
    try {
        foreach ($f in [System.IO.Directory]::GetFiles($script:BackupDir, '*.reg')) {
            $fi = New-Object System.IO.FileInfo($f)
            $o = New-Object PSObject -Property @{
                Path = $f
                Name = $fi.Name
                Time = $fi.LastWriteTime
                SizeKb = [int]($fi.Length / 1024)
            }
            [void]$items.Add($o)
        }
    } catch { }
    return $items
}

# ---------------------------------------------------------------------------
# SNTP-клиент (только чтение, ничего не меняет)
# ---------------------------------------------------------------------------
function Convert-NtpTimestamp {
    param([byte[]]$Buf, [int]$Offset)
    $sec = ([int64]$Buf[$Offset] * 16777216) + ([int64]$Buf[$Offset + 1] * 65536) + ([int64]$Buf[$Offset + 2] * 256) + [int64]$Buf[$Offset + 3]
    $fr  = ([int64]$Buf[$Offset + 4] * 16777216) + ([int64]$Buf[$Offset + 5] * 65536) + ([int64]$Buf[$Offset + 6] * 256) + [int64]$Buf[$Offset + 7]
    if ($sec -eq 0 -and $fr -eq 0) { return $null }
    $epoch = New-Object System.DateTime 1900, 1, 1, 0, 0, 0, ([System.DateTimeKind]::Utc)
    return $epoch.AddSeconds([double]$sec).AddSeconds([double]$fr / 4294967296.0)
}

function Invoke-SntpQuery {
    param(
        [string]$Server = '127.0.0.1',
        [int]$Port = 123,
        [int]$TimeoutMs = 3000
    )
    $epoch = New-Object System.DateTime 1900, 1, 1, 0, 0, 0, ([System.DateTimeKind]::Utc)
    $r = New-Object PSObject -Property @{
        Server       = $Server
        ServerIp     = ''
        Port         = $Port
        Success      = $false
        Error        = ''
        Leap         = 0
        Version      = 0
        Mode         = 0
        Stratum      = 0
        RefId        = ''
        RootDelayMs  = 0.0
        RootDispMs   = 0.0
        OffsetMs     = 0.0
        OffsetMeaning = ''
        DelayMs      = 0.0
        ServerUtc    = $null
        LocalUtc     = $null
        PacketLength = 0
        Unsynchronized = $false
    }
    $udp = $null
    try {
        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.Connect($Server, $Port)
        $udp.Client.ReceiveTimeout = $TimeoutMs

        $buf = New-Object byte[] 48
        $buf[0] = 0x1B          # LI = 0, VN = 3, Mode = 3 (клиент)
        $t1 = [System.DateTime]::UtcNow
        $since = ($t1 - $epoch).TotalSeconds
        $secWhole = [int64][Math]::Floor($since)
        $frac = [int64][Math]::Round(($since - [double]$secWhole) * 4294967296.0)
        if ($frac -gt 4294967295) { $frac = 4294967295 }
        if ($frac -lt 0) { $frac = 0 }
        $buf[40] = [byte](([Math]::Floor($secWhole / 16777216) % 256))
        $buf[41] = [byte](([Math]::Floor($secWhole / 65536) % 256))
        $buf[42] = [byte](([Math]::Floor($secWhole / 256) % 256))
        $buf[43] = [byte](($secWhole % 256))
        $buf[44] = [byte](([Math]::Floor($frac / 16777216) % 256))
        $buf[45] = [byte](([Math]::Floor($frac / 65536) % 256))
        $buf[46] = [byte](([Math]::Floor($frac / 256) % 256))
        $buf[47] = [byte](($frac % 256))

        [void]$udp.Send($buf, 48)
        $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $resp = $udp.Receive([ref]$ep)
        $t4 = [System.DateTime]::UtcNow
        $r.LocalUtc = $t4
        if ($resp -eq $null -or $resp.Length -lt 48) { throw 'Ответ короче 48 байт' }

        $r.PacketLength = $resp.Length
        $r.ServerIp = $ep.Address.ToString()
        $b0 = [int]$resp[0]
        $r.Leap    = [int][Math]::Floor($b0 / 64)
        $r.Version = [int]([Math]::Floor($b0 / 8) % 8)
        $r.Mode    = [int]($b0 % 8)
        $r.Stratum = [int]$resp[1]

        $rd = ([int64]$resp[4] * 16777216) + ([int64]$resp[5] * 65536) + ([int64]$resp[6] * 256) + [int64]$resp[7]
        $r.RootDelayMs = ([double]$rd / 65536.0) * 1000.0
        $rod = ([int64]$resp[8] * 16777216) + ([int64]$resp[9] * 65536) + ([int64]$resp[10] * 256) + [int64]$resp[11]
        $r.RootDispMs = ([double]$rod / 65536.0) * 1000.0

        if ($r.Stratum -le 1) {
            $chars = New-Object System.Collections.ArrayList
            for ($i = 12; $i -le 15; $i++) {
                if ($resp[$i] -ne 0) { [void]$chars.Add([char]$resp[$i]) }
            }
            $r.RefId = (-join $chars)
        } else {
            $r.RefId = ([string]$resp[12] + '.' + [string]$resp[13] + '.' + [string]$resp[14] + '.' + [string]$resp[15])
        }

        $t2 = Convert-NtpTimestamp $resp 32   # время приёма запроса сервером
        $t3 = Convert-NtpTimestamp $resp 40   # время отправки ответа сервером
        if ($t3 -ne $null) { $r.ServerUtc = $t3 }

        if ($t2 -ne $null -and $t3 -ne $null) {
            # offset = (локальное время - время сервера); > 0 значит наши часы спешат
            $r.OffsetMs = ((($t1 - $t2).TotalMilliseconds) + (($t4 - $t3).TotalMilliseconds)) / 2.0
            $r.OffsetMeaning = 'точный расчёт по 4 меткам'
            $r.DelayMs = (($t4 - $t1).TotalMilliseconds) - (($t3 - $t2).TotalMilliseconds)
        } else {
            $r.OffsetMs = ($t3 - $t4).TotalMilliseconds * -1.0
            $r.OffsetMeaning = 'приблизительно (сервер не вернул метки приёма/передачи)'
            $r.DelayMs = ($t4 - $t1).TotalMilliseconds
        }
        if ($r.DelayMs -lt 0) { $r.DelayMs = ($t4 - $t1).TotalMilliseconds }

        if ($r.Leap -eq 3 -or $r.Stratum -eq 0 -or $r.Stratum -ge 16) { $r.Unsynchronized = $true }
        $r.Success = $true
    } catch {
        $msg = $_.Exception.Message
        if ($_.Exception.InnerException -ne $null) { $msg = $msg + ' / ' + $_.Exception.InnerException.Message }
        $r.Error = $msg
    } finally {
        if ($udp -ne $null) { try { $udp.Close() } catch { } }
    }
    return $r
}

function Invoke-SntpStability {
    param([string]$Server = '127.0.0.1', [int]$Samples = 5, [int]$PauseMs = 800, [int]$TimeoutMs = 3000)
    $list = New-Object System.Collections.ArrayList
    for ($i = 1; $i -le $Samples; $i++) {
        $q = Invoke-SntpQuery -Server $Server -Port $script:NtpPort -TimeoutMs $TimeoutMs
        [void]$list.Add($q)
        if ($i -lt $Samples) { Start-Sleep -Milliseconds $PauseMs }
    }
    $ok = @($list | Where-Object { $_.Success -eq $true })
    $stat = New-Object PSObject -Property @{
        Server      = $Server
        Samples     = $Samples
        Received    = $ok.Count
        Lost        = $Samples - $ok.Count
        MinOffsetMs = 0.0
        MaxOffsetMs = 0.0
        AvgOffsetMs = 0.0
        AvgDelayMs  = 0.0
        Stratum     = 0
        Results     = $list.ToArray()
    }
    if ($ok.Count -gt 0) {
        $offsets = @($ok | ForEach-Object { [double]$_.OffsetMs })
        $delays  = @($ok | ForEach-Object { [double]$_.DelayMs })
        $stat.MinOffsetMs = ($offsets | Measure-Object -Minimum).Minimum
        $stat.MaxOffsetMs = ($offsets | Measure-Object -Maximum).Maximum
        $stat.AvgOffsetMs = [Math]::Round(($offsets | Measure-Object -Average).Average, 2)
        $stat.AvgDelayMs  = [Math]::Round(($delays | Measure-Object -Average).Average, 2)
        $stat.Stratum     = [int]$ok[0].Stratum
    }
    return $stat
}

# ---------------------------------------------------------------------------
# Универсальная проверка сервера времени: встроенный SNTP-клиент, а если в этом
# сеансе PowerShell недоступен сетевой стек .NET - резервная проверка w32tm
# ---------------------------------------------------------------------------
function Test-SntpStack {
    if ($script:SntpStackOk -ne $null) { return $script:SntpStackOk }
    $script:SntpStackOk = $false
    $script:SntpStackError = ''
    try {
        $ip = [System.Net.IPAddress]::Parse('127.0.0.1')
        if ($ip -ne $null) { $script:SntpStackOk = $true }
    } catch {
        $msg = $_.Exception.Message
        if ($_.Exception.InnerException -ne $null) { $msg = $_.Exception.InnerException.Message }
        $script:SntpStackError = $msg
    }
    return $script:SntpStackOk
}

function Invoke-W32tmStripCheck {
    param([string]$Server = '127.0.0.1', [int]$Samples = 2, [int]$TimeoutSec = 120)
    $r = Invoke-W32tm ('/stripchart /computer:' + $Server + ' /samples:' + $Samples) $TimeoutSec
    $raw = Get-ExeText $r -WithErrors
    $res = New-Object PSObject -Property @{
        Server = $Server; Success = $false; Good = 0; Lost = 0
        AvgDelaySec = 0.0; AvgOffsetSec = 0.0; MinOffsetSec = 0.0; MaxOffsetSec = 0.0
        Raw = $raw; ExitCode = $r.ExitCode
    }
    $offsets = New-Object System.Collections.ArrayList
    $delays  = New-Object System.Collections.ArrayList
    foreach ($line in ($raw -split "`r?`n")) {
        if ($line -match 'd:([+-]?[0-9]+[.,]?[0-9]*)s\s+o:([+-]?[0-9]+[.,]?[0-9]*)s') {
            [void]$delays.Add([double](($Matches[1] -replace ',', '.')))
            [void]$offsets.Add([double](($Matches[2] -replace ',', '.')))
        }
    }
    $res.Good = $offsets.Count
    $res.Lost = $Samples - $res.Good
    if ($res.Lost -lt 0) { $res.Lost = 0 }
    if ($res.Good -gt 0) {
        $res.Success = $true
        $res.AvgDelaySec  = [Math]::Round((($delays | Measure-Object -Average).Average), 6)
        $res.AvgOffsetSec = [Math]::Round((($offsets | Measure-Object -Average).Average), 6)
        $res.MinOffsetSec = [Math]::Round((($offsets | Measure-Object -Minimum).Minimum), 6)
        $res.MaxOffsetSec = [Math]::Round((($offsets | Measure-Object -Maximum).Maximum), 6)
    }
    return $res
}

function Invoke-NtpCheck {
    param([string]$Server = '127.0.0.1', [int]$Samples = 1, [int]$PauseMs = 500, [int]$TimeoutMs = 2500)
    $res = New-Object PSObject -Property @{
        Server = $Server; Source = ''; Success = $false; Samples = $Samples; Received = 0; Lost = 0
        Stratum = 0; RefId = ''; OffsetMs = 0.0; MinOffsetMs = 0.0; MaxOffsetMs = 0.0; DelayMs = 0.0
        Unsynchronized = $false; Error = ''; Text = ''
    }
    if (Test-SntpStack) {
        $res.Source = 'sntp'
        if ($Samples -le 1) {
            $q = Invoke-SntpQuery -Server $Server -Port $script:NtpPort -TimeoutMs $TimeoutMs
            $res.Text = Format-SntpResult $q ('Источник времени ' + $Server)
            $res.Success = $q.Success
            if ($q.Success) { $res.Received = 1 }
            $res.Lost = 1 - $res.Received
            $res.Stratum = $q.Stratum
            $res.RefId = $q.RefId
            $res.OffsetMs = $q.OffsetMs
            $res.MinOffsetMs = $q.OffsetMs
            $res.MaxOffsetMs = $q.OffsetMs
            $res.DelayMs = $q.DelayMs
            $res.Unsynchronized = $q.Unsynchronized
            $res.Error = $q.Error
        } else {
            $s = Invoke-SntpStability -Server $Server -Samples $Samples -PauseMs $PauseMs -TimeoutMs $TimeoutMs
            $res.Success = ($s.Received -gt 0)
            $res.Received = $s.Received
            $res.Lost = $s.Lost
            $res.Stratum = $s.Stratum
            $res.OffsetMs = $s.AvgOffsetMs
            $res.MinOffsetMs = $s.MinOffsetMs
            $res.MaxOffsetMs = $s.MaxOffsetMs
            $res.DelayMs = $s.AvgDelayMs
            $sb = New-Object System.Text.StringBuilder
            [void]$sb.AppendLine((Format-StabilityResult $s))
            foreach ($q in $s.Results) {
                if ($q.Success) { [void]$sb.AppendLine('  ' + $q.Server + ': смещение ' + [Math]::Round($q.OffsetMs, 1) + ' мс, задержка ' + [Math]::Round($q.DelayMs, 1) + ' мс') }
                else { [void]$sb.AppendLine('  ' + $q.Server + ': нет ответа (' + $q.Error + ')') }
            }
            $res.Text = $sb.ToString()
        }
        return $res
    }

    # --- резервный путь: сетевой стек .NET в этом сеансе недоступен ---
    $res.Source = 'w32tm'
    $c = Invoke-W32tmStripCheck -Server $Server -Samples $Samples -TimeoutSec 120
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('--- Источник времени ' + $Server + ' (проверка через w32tm) ---')
    [void]$sb.AppendLine('Примечание: встроенный SNTP-клиент недоступен в этом сеансе PowerShell (' + $script:SntpStackError + ').')
    [void]$sb.AppendLine('Проверка выполнена системной утилитой w32tm /stripchart: без stratum и идентификатора источника.')
    if ($c.Success) {
        [void]$sb.AppendLine('Отклик       : есть, успешных замеров ' + $c.Good + ' из ' + $Samples)
        [void]$sb.AppendLine('Задержка d:  : ' + [Math]::Round($c.AvgDelaySec * 1000, 3) + ' мс')
        [void]$sb.AppendLine('Смещение o:  : ' + [Math]::Round($c.AvgOffsetSec * 1000, 3) + ' мс (знак — как в выводе w32tm)')
        [void]$sb.AppendLine('Вывод        : сервер отвечает на NTP-запросы')
    } else {
        [void]$sb.AppendLine('Отклик       : НЕТ')
        [void]$sb.AppendLine('Вывод        : сервер не ответил на запросы — проверьте сеть и входящий UDP 123 на нём')
    }
    [void]$sb.AppendLine('Сырой вывод w32tm:')
    foreach ($l in ($c.Raw -split "`r?`n")) { [void]$sb.AppendLine('  ' + $l) }
    $res.Text = $sb.ToString()
    $res.Success = $c.Success
    $res.Received = $c.Good
    $res.Lost = $c.Lost
    $res.OffsetMs = $c.AvgOffsetSec * 1000
    $res.MinOffsetMs = $c.MinOffsetSec * 1000
    $res.MaxOffsetMs = $c.MaxOffsetSec * 1000
    $res.DelayMs = $c.AvgDelaySec * 1000
    if (-not $c.Success) { $res.Error = 'нет ответа (проверено через w32tm /stripchart)' }
    return $res
}

# ---------------------------------------------------------------------------
# Применение настроек
# ---------------------------------------------------------------------------
function Get-RecommendedOptions {
    param([string]$GpsPeer = '', [int]$PollSeconds = 300)
    $o = @{}
    $o['ServerEnabled']    = 1
    $o['AllowNonstandard'] = 1
    $o['ClientEnabled']    = 1
    $o['Type']             = 'NTP'
    if ($GpsPeer -ne '') { $o['Peers'] = (Get-PeerListNormalized $GpsPeer) }
    $o['PollInterval']     = $PollSeconds
    $o['Reliable']         = $true
    $o['StartupMode']      = 'Automatic'
    return $o
}

# Регистрация службы времени заново: именно это нужно, когда службы нет в списке
# (обычно после w32tm /unregister или удаления ключа службы «оптимизаторами»).
function Register-TimeService {
    $log = New-Object System.Collections.ArrayList
    $dll = [System.IO.Path]::Combine($env:SystemRoot, 'System32\w32time.dll')
    if (-not [System.IO.File]::Exists($dll)) {
        [void]$log.Add('ОШИБКА: файл %windir%\system32\w32time.dll не найден. Без него регистрация не поможет — восстановите файл (sfc /scannow) или с установочного диска.')
        return $log
    }
    [void](Backup-W32TimeRegistry)
    $r = Invoke-W32tm '/register' 120
    [void]$log.Add('w32tm /register -> код ' + $r.ExitCode)
    $txt = Get-ExeText $r -WithErrors
    if ($txt -ne '') { [void]$log.Add($txt) }
    Add-Log ('w32tm /register -> код ' + $r.ExitCode)
    $e = Set-TimeServiceStartupMode 'Automatic'
    if ($e -ne '') { [void]$log.Add('Тип запуска: ' + $e) } else { [void]$log.Add('Тип запуска службы: Автоматически'); Add-Log 'Тип запуска службы: Автоматически' }
    $e2 = Start-TimeService -TimeoutSec 60
    if ($e2 -ne '') { [void]$log.Add('Запуск службы: ' + $e2) } else { [void]$log.Add('Служба времени запущена.'); Add-Log 'Служба времени зарегистрирована и запущена.' }
    $st = Get-NtpConfigState
    if (-not $st.NtpServerKeyExists) { [void]$log.Add('Примечание: ключ TimeProviders\NtpServer пока отсутствует — включите провайдер NtpServer на вкладке «Настройка».') }
    return $log
}

# Сохранение ветви групповой политики службы времени в рег-файл.
function Export-PolicyBranchBackup {
    if (-not (Test-RegKeyExists 'SOFTWARE\Policies\Microsoft\W32Time')) { return '' }
    $path = [System.IO.Path]::Combine($script:BackupDir, ('W32Time-policy_' + (Get-Date).ToString('yyyyMMdd_HHmmss') + '.reg'))
    $r = Invoke-Exe -FilePath (Get-ToolPath 'reg.exe') -ArgumentString ('export "HKLM\SOFTWARE\Policies\Microsoft\W32Time" "' + $path + '" /y') -TimeoutSec 60
    if ($r.ExitCode -eq 0 -and [System.IO.File]::Exists($path)) {
        Add-Log ('Резервная копия ветви политики: ' + $path)
        return $path
    }
    Add-Log ('Не удалось сохранить ветвь политики: ' + (Get-ExeText $r -WithErrors)) 'WARN'
    return ''
}

# Удаление ветви групповой политики службы времени (с предварительной резервной копией).
function Remove-W32TimePolicyBranch {
    if (-not (Test-RegKeyExists 'SOFTWARE\Policies\Microsoft\W32Time')) { return 'ветвь политики не найдена — удалять нечего' }
    [void](Export-PolicyBranchBackup)
    $r = Invoke-Exe -FilePath (Get-ToolPath 'reg.exe') -ArgumentString 'delete "HKLM\SOFTWARE\Policies\Microsoft\W32Time" /f' -TimeoutSec 60
    if ($r.ExitCode -ne 0) { return (Get-ExeText $r -WithErrors) }
    Add-Log 'Ветвь групповой политики службы времени удалена (резервная копия сохранена).'
    return ''
}

function Set-NtpConfiguration {
    param([hashtable]$Options, [switch]$Preview)
    $root    = $script:RegRoot
    $st      = Get-NtpConfigState
    $changes = New-Object System.Collections.ArrayList
    $errors  = New-Object System.Collections.ArrayList

    # ---- целевые значения (пусто = не менять) ----
    $tServer = $null
    if ($Options.ContainsKey('ServerEnabled') -and $Options['ServerEnabled'] -ne $null) { $tServer = [int]$Options['ServerEnabled'] }
    $tAllow = $null
    if ($Options.ContainsKey('AllowNonstandard') -and $Options['AllowNonstandard'] -ne $null) { $tAllow = [int]$Options['AllowNonstandard'] }
    $tClient = $null
    if ($Options.ContainsKey('ClientEnabled') -and $Options['ClientEnabled'] -ne $null) { $tClient = [int]$Options['ClientEnabled'] }
    $tType = $null
    if ($Options.ContainsKey('Type') -and $Options['Type'] -ne $null -and $Options['Type'] -ne '') { $tType = [string]$Options['Type'] }
    $tPeers = $null
    if ($Options.ContainsKey('Peers') -and $Options['Peers'] -ne $null) { $tPeers = Get-PeerListNormalized ([string]$Options['Peers']) }
    $tPoll = $null
    if ($Options.ContainsKey('PollInterval') -and $Options['PollInterval'] -ne $null -and [int]$Options['PollInterval'] -gt 0) { $tPoll = [int]$Options['PollInterval'] }
    $tAnnounce = $null
    if ($Options.ContainsKey('AnnounceFlags') -and $Options['AnnounceFlags'] -ne $null) { $tAnnounce = [int]$Options['AnnounceFlags'] }
    if ($Options.ContainsKey('Reliable') -and $Options['Reliable'] -ne $null) {
        if ($Options['Reliable'] -eq $true) { $tAnnounce = 5 } else { $tAnnounce = 10 }
    }
    $tPhase = $null
    if ($Options.ContainsKey('MaxAllowedPhaseOffset') -and $Options['MaxAllowedPhaseOffset'] -ne $null -and [int]$Options['MaxAllowedPhaseOffset'] -ge 0) { $tPhase = [int]$Options['MaxAllowedPhaseOffset'] }
    $tEvents = $null
    if ($Options.ContainsKey('EventLogFlags') -and $Options['EventLogFlags'] -ne $null -and [int]$Options['EventLogFlags'] -ge 0) { $tEvents = [int]$Options['EventLogFlags'] }
    $tStartup = $null
    if ($Options.ContainsKey('StartupMode') -and $Options['StartupMode'] -ne $null -and $Options['StartupMode'] -ne '') { $tStartup = [string]$Options['StartupMode'] }

    $usePolicy = $false
    if ($Options.ContainsKey('UsePolicyBranch') -and $Options['UsePolicyBranch'] -eq $true) { $usePolicy = $true }

    # ---- список изменений ----
    $curServer = 0; if ($st.ServerEnabled -ne $null) { $curServer = [int]$st.ServerEnabled }
    if ($tServer -ne $null -and $tServer -ne $curServer) {
        [void]$changes.Add('Провайдер NtpServer (раздача времени в сеть): ' + (Convert-BoolRu $curServer) + ' -> ' + (Convert-BoolRu $tServer))
    }
    $curClient = 0; if ($st.ClientEnabled -ne $null) { $curClient = [int]$st.ClientEnabled }
    if ($tClient -ne $null -and $tClient -ne $curClient) {
        [void]$changes.Add('Провайдер NtpClient (получение времени): ' + (Convert-BoolRu $curClient) + ' -> ' + (Convert-BoolRu $tClient))
    }
    $curAllow = 0; if ($st.AllowNonstandard -ne $null) { $curAllow = [int]$st.AllowNonstandard }
    if ($tAllow -ne $null -and $tAllow -ne $curAllow) {
        [void]$changes.Add('AllowNonstandardModeCombinations (совместимость с нестандартными клиентами): ' + (Convert-BoolRu $curAllow) + ' -> ' + (Convert-BoolRu $tAllow))
    }
    if ($tType -ne $null -and ([string]$st.Type) -ne $tType) {
        [void]$changes.Add('Parameters\Type (тип источника времени): ' + [string]$st.Type + ' -> ' + $tType)
    }
    if ($tPeers -ne $null -and $tPeers -ne '') {
        $curPeers = ''
        if ($st.Peers -ne $null) { $curPeers = Get-PeerListNormalized ([string]$st.Peers) }
        if ($curPeers -ne $tPeers) {
            [void]$changes.Add('Parameters\NtpServer (список серверов времени): "' + $curPeers + '" -> "' + $tPeers + '"')
        }
    }
    if ($tPoll -ne $null -and ([int]$st.SpecialPollInterval -ne $tPoll)) {
        $curPoll = 'не задано'
        if ($st.SpecialPollInterval -ne $null) { $curPoll = [string]$st.SpecialPollInterval + ' с' }
        [void]$changes.Add('SpecialPollInterval (интервал опроса сервера времени): ' + $curPoll + ' -> ' + [string]$tPoll + ' с')
    }
    if ($tAnnounce -ne $null -and ([int]$st.AnnounceFlags -ne $tAnnounce)) {
        $curAnn = 'не задано'
        if ($st.AnnounceFlags -ne $null) { $curAnn = [string]$st.AnnounceFlags }
        $meaning = '10 = обычный участник'
        if ($tAnnounce -eq 5) { $meaning = '5 = надёжный источник времени' }
        [void]$changes.Add('AnnounceFlags: ' + $curAnn + ' -> ' + [string]$tAnnounce + ' (' + $meaning + ')')
    }
    if ($tPhase -ne $null -and ([int]$st.MaxAllowedPhaseOffset -ne $tPhase)) {
        $cur = 'не задано'
        if ($st.MaxAllowedPhaseOffset -ne $null) { $cur = [string]$st.MaxAllowedPhaseOffset + ' с' }
        [void]$changes.Add('MaxAllowedPhaseOffset (порог исправления смещения): ' + $cur + ' -> ' + [string]$tPhase + ' с')
    }
    if ($tEvents -ne $null -and ([int]$st.EventLogFlags -ne $tEvents)) {
        $cur = 'не задано'
        if ($st.EventLogFlags -ne $null) { $cur = [string]$st.EventLogFlags }
        [void]$changes.Add('EventLogFlags (подробность журнала событий): ' + $cur + ' -> ' + [string]$tEvents)
    }
    if ($tStartup -ne $null) {
        $snap = Get-ServiceSnapshot
        $wantRu = Convert-StartModeRu $tStartup
        if ($snap.StartModeRu -ne $wantRu) {
            [void]$changes.Add('Тип запуска службы: ' + $snap.StartModeRu + ' -> ' + $wantRu)
        }
    }
    if ($Options.ContainsKey('AddFirewall') -and $Options['AddFirewall'] -eq $true) {
        $fwInfo = Get-NtpFirewallRuleInfo
        if ($fwInfo.Exists) { [void]$changes.Add('Правило брандмауэра: уже существует') }
        else { [void]$changes.Add('Правило брандмауэра: добавить входящее разрешение UDP ' + $script:NtpPort) }
    }
    if ($Options.ContainsKey('RemoveFirewall') -and $Options['RemoveFirewall'] -eq $true) {
        $fwInfo = Get-NtpFirewallRuleInfo
        if ($fwInfo.Exists) { [void]$changes.Add('Правило брандмауэра: удалить разрешение UDP ' + $script:NtpPort) }
        else { [void]$changes.Add('Правило брандмауэра: не найдено, удалять нечего') }
    }
    if ($usePolicy) {
        [void]$changes.Add('ВЕТВЬ ПОЛИТИКИ: те же параметры будут записаны и в HKLM\SOFTWARE\Policies\Microsoft\W32Time (Config, Parameters, TimeProviders) — именно эти значения имеет приоритет, если служба управляется политикой')
    }

    if ($Preview) { return $changes }
    if ($changes.Count -eq 0) {
        Add-Log 'Изменений не требуется: настройки уже соответствуют заданным.'
        return $changes
    }

    if (-not $script:IsAdmin) {
        throw 'Для изменения настроек нужны права администратора.'
    }

    # ---- 1. Резервная копия ----
    [void](Backup-W32TimeRegistry)

    # ---- 2. Остановка службы (нужна для смены провайдеров и интервала опроса) ----
    $needRestart = $false
    if ($tServer -ne $null -or $tClient -ne $null -or $tAllow -ne $null -or $tPoll -ne $null -or $tPhase -ne $null -or $tEvents -ne $null) { $needRestart = $true }
    $restartAllowed = $true
    if ($Options.ContainsKey('Restart') -and $Options['Restart'] -eq $false) { $restartAllowed = $false }
    if ($needRestart -and $restartAllowed) {
        Add-Log 'Останавливаю службу времени для применения настроек...'
        $e = Stop-TimeService -TimeoutSec 40
        if ($e -ne '') {
            Add-Log ('Не удалось остановить службу: ' + $e) 'ERROR'
            [void]$errors.Add('Остановка службы: ' + $e)
        }
    }

    # ---- 3. Запись значений в реестр ----
    try {
        # Провайдер NTP-сервера
        if ($tServer -ne $null -or $tAllow -ne $null) {
            $created = Ensure-RegKey ($root + '\TimeProviders\NtpServer')
            if ($created) {
                Set-RegValue ($root + '\TimeProviders\NtpServer') 'DllName' '%systemroot%\system32\w32time.dll' 'ExpandString'
                Set-RegValue ($root + '\TimeProviders\NtpServer') 'InputProvider' 0 'DWord'
                Add-Log 'Ключ TimeProviders\NtpServer отсутствовал и был создан заново.' 'WARN'
            }
            if ($tServer -ne $null) {
                Set-RegValue ($root + '\TimeProviders\NtpServer') 'Enabled' $tServer 'DWord'
                Add-Log ('TimeProviders\NtpServer\Enabled = ' + $tServer)
            }
            if ($tAllow -ne $null) {
                Set-RegValue ($root + '\TimeProviders\NtpServer') 'AllowNonstandardModeCombinations' $tAllow 'DWord'
                Add-Log ('TimeProviders\NtpServer\AllowNonstandardModeCombinations = ' + $tAllow)
            }
        }

        # Провайдер NTP-клиента
        if ($tClient -ne $null -or $tPoll -ne $null) {
            $created = Ensure-RegKey ($root + '\TimeProviders\NtpClient')
            if ($created) {
                Set-RegValue ($root + '\TimeProviders\NtpClient') 'DllName' '%systemroot%\system32\w32time.dll' 'ExpandString'
                Set-RegValue ($root + '\TimeProviders\NtpClient') 'InputProvider' 0 'DWord'
                Add-Log 'Ключ TimeProviders\NtpClient отсутствовал и был создан заново.' 'WARN'
            }
            if ($tClient -ne $null) {
                Set-RegValue ($root + '\TimeProviders\NtpClient') 'Enabled' $tClient 'DWord'
                Add-Log ('TimeProviders\NtpClient\Enabled = ' + $tClient)
            }
            if ($tPoll -ne $null) {
                Set-RegValue ($root + '\TimeProviders\NtpClient') 'SpecialPollInterval' $tPoll 'DWord'
                Add-Log ('TimeProviders\NtpClient\SpecialPollInterval = ' + $tPoll + ' с')
                Remove-RegValue ($root + '\TimeProviders\NtpClient') 'SpecialPollTimeRemaining'
            }
        }

        # Источник времени
        if ($tType -ne $null -or ($tPeers -ne $null -and $tPeers -ne '')) {
            [void](Ensure-RegKey ($root + '\Parameters'))
            if ($tType -ne $null) {
                Set-RegValue ($root + '\Parameters') 'Type' $tType 'String'
                Add-Log ('Parameters\Type = ' + $tType)
            }
            if ($tPeers -ne $null -and $tPeers -ne '') {
                Set-RegValue ($root + '\Parameters') 'NtpServer' $tPeers 'String'
                Add-Log ('Parameters\NtpServer = "' + $tPeers + '"')
            }
        }

        # Прочие параметры Config
        if ($tAnnounce -ne $null -or $tPhase -ne $null -or $tEvents -ne $null) {
            [void](Ensure-RegKey ($root + '\Config'))
            if ($tAnnounce -ne $null) {
                Set-RegValue ($root + '\Config') 'AnnounceFlags' $tAnnounce 'DWord'
                Add-Log ('Config\AnnounceFlags = ' + $tAnnounce)
            }
            if ($tPhase -ne $null) {
                Set-RegValue ($root + '\Config') 'MaxAllowedPhaseOffset' $tPhase 'DWord'
                Add-Log ('Config\MaxAllowedPhaseOffset = ' + $tPhase + ' с')
            }
            if ($tEvents -ne $null) {
                Set-RegValue ($root + '\Config') 'EventLogFlags' $tEvents 'DWord'
                Add-Log ('Config\EventLogFlags = ' + $tEvents)
            }
        }
        if ($usePolicy) {
            $proot = 'SOFTWARE\Policies\Microsoft\W32Time'
            [void](Export-PolicyBranchBackup)
            if ($tServer -ne $null) { Set-RegValue ($proot + '\TimeProviders\NtpServer') 'Enabled' $tServer 'DWord' }
            if ($tAllow -ne $null) { Set-RegValue ($proot + '\TimeProviders\NtpServer') 'AllowNonstandardModeCombinations' $tAllow 'DWord' }
            if ($tClient -ne $null) { Set-RegValue ($proot + '\TimeProviders\NtpClient') 'Enabled' $tClient 'DWord' }
            if ($tPoll -ne $null) { Set-RegValue ($proot + '\TimeProviders\NtpClient') 'SpecialPollInterval' $tPoll 'DWord' }
            if ($tType -ne $null) { Set-RegValue ($proot + '\Parameters') 'Type' $tType 'String' }
            if ($tPeers -ne $null -and $tPeers -ne '') { Set-RegValue ($proot + '\Parameters') 'NtpServer' $tPeers 'String' }
            if ($tAnnounce -ne $null) { Set-RegValue ($proot + '\Config') 'AnnounceFlags' $tAnnounce 'DWord' }
            if ($tPhase -ne $null) { Set-RegValue ($proot + '\Config') 'MaxAllowedPhaseOffset' $tPhase 'DWord' }
            if ($tEvents -ne $null) { Set-RegValue ($proot + '\Config') 'EventLogFlags' $tEvents 'DWord' }
            Add-Log 'Параметры записаны также в ветвь групповой политики (SOFTWARE\Policies\Microsoft\W32Time).'
        }
        Add-Log 'Значения в реестре записаны.'
    } catch {
        Add-Log ('Ошибка записи в реестр: ' + $_.Exception.Message) 'ERROR'
        [void]$errors.Add('Реестр: ' + $_.Exception.Message)
    }

    # ---- 4. Запуск службы ----
    if ($needRestart -and $restartAllowed) {
        $e = Start-TimeService -TimeoutSec 40
        if ($e -ne '') {
            Add-Log ('Не удалось запустить службу: ' + $e) 'ERROR'
            [void]$errors.Add('Запуск службы: ' + $e)
        } else {
            Add-Log 'Служба времени запущена.'
        }
    } elseif ($needRestart) {
        Add-Log 'Служба не перезапускалась (ключ -NoRestart): новый провайдер заработает после перезапуска службы.' 'WARN'
    }

    # ---- 5. Уведомление службы о новых параметрах ----
    $syncFlags = ''
    if ($tType -ne $null) {
        switch ($tType) {
            'NTP'    { $syncFlags = 'manual' }
            'NT5DS'  { $syncFlags = 'domhier' }
            'AllSync'{ $syncFlags = 'all' }
            'NoSync' { $syncFlags = 'nosync' }
        }
    }
    if ($tPeers -ne $null -and $tPeers -ne '') {
        $cfgArgs = '/config /manualpeerlist:"' + $tPeers + '"'
        if ($syncFlags -ne '') { $cfgArgs = $cfgArgs + ' /syncfromflags:' + $syncFlags }
        if ($tAnnounce -eq 5) { $cfgArgs = $cfgArgs + ' /reliable:yes' }
        if ($tAnnounce -eq 10) { $cfgArgs = $cfgArgs + ' /reliable:no' }
        $cfgArgs = $cfgArgs + ' /update'
        $r = Invoke-W32tm -Arguments $cfgArgs -TimeoutSec 60
        Add-Log ('w32tm ' + $cfgArgs + ' -> код ' + $r.ExitCode)
        if ($r.ExitCode -ne 0) { Add-Log (Get-ExeText $r -WithErrors) 'WARN' }
    } elseif ($syncFlags -ne '') {
        $r = Invoke-W32tm -Arguments ('/config /syncfromflags:' + $syncFlags + ' /update') -TimeoutSec 60
        Add-Log ('w32tm /config /syncfromflags:' + $syncFlags + ' /update -> код ' + $r.ExitCode)
    }

    # ---- 6. Принудительная синхронизация (не критично, если не удалась) ----
    if ($tPeers -ne $null -and $tPeers -ne '' -and $restartAllowed) {
        $rs = Invoke-W32tm -Arguments '/resync /rediscover' -TimeoutSec 60
        if ($rs.ExitCode -ne 0) {
            $rs = Invoke-W32tm -Arguments '/resync' -TimeoutSec 60
        }
        Add-Log ('w32tm /resync -> код ' + $rs.ExitCode + ': ' + (Get-ExeText $rs -WithErrors))
    }

    # ---- 7. Тип запуска службы ----
    if ($tStartup -ne $null) {
        $e = Set-TimeServiceStartupMode $tStartup
        if ($e -ne '') {
            Add-Log ('Не удалось изменить тип запуска: ' + $e) 'ERROR'
            [void]$errors.Add('Тип запуска: ' + $e)
        } else {
            Add-Log ('Тип запуска службы: ' + (Convert-StartModeRu $tStartup))
        }
    }

    # ---- 8. Брандмауэр ----
    if ($Options.ContainsKey('AddFirewall') -and $Options['AddFirewall'] -eq $true) {
        if (-not (Get-NtpFirewallRuleInfo).Exists) {
            $r = Add-NtpFirewallRule
            if ($r.ExitCode -eq 0) { Add-Log ('Брандмауэр: добавлено правило входящего UDP ' + $script:NtpPort) }
            else {
                Add-Log ('Брандмауэр: не удалось добавить правило: ' + (Get-ExeText $r -WithErrors)) 'ERROR'
                [void]$errors.Add('Брандмауэр: ' + (Get-ExeText $r -WithErrors))
            }
        }
    }
    if ($Options.ContainsKey('RemoveFirewall') -and $Options['RemoveFirewall'] -eq $true) {
        $r = Remove-NtpFirewallRule
        if ($r.ExitCode -eq 0) { Add-Log ('Брандмауэр: правило для UDP ' + $script:NtpPort + ' удалено') }
        else { Add-Log ('Брандмауэр: правило не удалено: ' + (Get-ExeText $r -WithErrors)) 'WARN' }
    }

    $script:LastApplyErrors = $errors
    return $changes
}

# ---------------------------------------------------------------------------
# Настройки самой утилиты (ini рядом со скриптом)
# ---------------------------------------------------------------------------
function Get-Settings {
    $s = @{}
    $s['ServerList']    = ''
    $s['PollInterval']  = '300'
    $s['Type']          = 'NTP'
    $s['EnableServer']  = '1'
    $s['AllowNonstandard'] = '1'
    $s['EnableClient']  = '1'
    $s['Reliable']      = '1'
    $s['StartupMode']   = 'Automatic'
    $s['AddFirewall']   = '0'
    $s['MaxAllowedPhaseOffset'] = ''
    $s['EventLogFlags'] = ''
    $s['AutoRefreshSec'] = '15'
    $s['MonitorSntp']   = '0'
    $s['NotifyOnChange'] = '1'
    $s['PeerFlag']      = '1'
    $s['PolicyMode']    = '0'
    $s['Language']      = ''
    $s['ExpectedServer'] = '1'
    $s['ExpectedClient'] = '1'
    $s['CheckServer']   = ''
    $s['MinimizeToTray'] = '0'
    try {
        if ([System.IO.File]::Exists($script:SettingsFile)) {
            $text = [System.IO.File]::ReadAllText($script:SettingsFile, (New-Object System.Text.UTF8Encoding($false)))
            foreach ($line in ($text -split "`r?`n")) {
                $t = $line.Trim()
                if ($t -eq '' -or $t.StartsWith('#') -or $t.StartsWith(';')) { continue }
                $i = $t.IndexOf('=')
                if ($i -lt 1) { continue }
                $key = $t.Substring(0, $i).Trim()
                $val = $t.Substring($i + 1).Trim()
                if ($s.ContainsKey($key)) { $s[$key] = $val }
            }
        }
    } catch { }
    return $s
}

function Save-Settings {
    param([hashtable]$Settings)
    $order = @('ServerList', 'PollInterval', 'Type', 'EnableServer', 'AllowNonstandard', 'EnableClient', 'Reliable',
               'StartupMode', 'AddFirewall', 'MaxAllowedPhaseOffset', 'EventLogFlags', 'AutoRefreshSec',
               'MonitorSntp', 'NotifyOnChange', 'ExpectedServer', 'ExpectedClient', 'CheckServer', 'MinimizeToTray', 'PeerFlag', 'PolicyMode', 'Language')
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('# Настройки NtpManager (можно править вручную, кодировка UTF-8)')
    [void]$sb.AppendLine('# ServerList     - список серверов времени, например: 192.168.1.50,0x9')
    [void]$sb.AppendLine('# PollInterval   - интервал опроса сервера времени, секунды')
    [void]$sb.AppendLine('# AutoRefreshSec - период автообновления окна, секунды')
    foreach ($k in $order) {
        $v = ''
        if ($Settings.ContainsKey($k) -and $Settings[$k] -ne $null) { $v = [string]$Settings[$k] }
        [void]$sb.AppendLine($k + '=' + $v)
    }
    try {
        [System.IO.File]::WriteAllText($script:SettingsFile, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
        return $true
    } catch {
        Add-Log ('Не удалось сохранить настройки: ' + $_.Exception.Message) 'ERROR'
        return $false
    }
}

# ---------------------------------------------------------------------------
# Журнал событий службы времени
# ---------------------------------------------------------------------------
function Get-W32TimeEvents {
    param([int]$Max = 8)
    $out = New-Object System.Collections.ArrayList
    # 1) Современный поставщик событий (Windows 8 / Server 2012 и новее, включая Windows 10/11).
    #    Используется -FilterXPath, а не -FilterHashtable: последний появился только в PowerShell 3.0,
    #    а утилита должна работать и в PowerShell 2.0 (Windows Server 2008 R2).
    try {
        $ev = Get-WinEvent -LogName System -FilterXPath "*[System[Provider[@Name='Microsoft-Windows-Time-Service']]]" -MaxEvents $Max -ErrorAction Stop
        foreach ($e in @($ev)) {
            if ($e -eq $null) { continue }
            $msg = ''
            try { $msg = [string]$e.Message } catch { }
            $o = New-Object PSObject -Property @{ Time = $e.TimeCreated; Id = $e.Id; Source = [string]$e.ProviderName; Message = $msg }
            [void]$out.Add($o)
        }
    } catch { }
    # 2) Классический источник W32Time (Windows Server 2008 R2 / Windows 7).
    if ($out.Count -eq 0) {
        try {
            $ev2 = Get-EventLog -LogName System -Source 'W32Time' -Newest $Max -ErrorAction SilentlyContinue
            foreach ($e in @($ev2)) {
                if ($e -eq $null) { continue }
                $o = New-Object PSObject -Property @{ Time = $e.TimeGenerated; Id = $e.EventID; Source = [string]$e.Source; Message = [string]$e.Message }
                [void]$out.Add($o)
            }
        } catch { }
    }
    if ($out.Count -eq 0) {
        # Дорогой путь (перебор всего журнала System) выполняется не чаще раза в 10 минут:
        # иначе каждое автообновление окна перечитывает сотни событий и интерфейс подвисает.
        $nowT = Get-Date
        $allow = $true
        if ($script:EventsFallbackUntil -ne $null) {
            if ($nowT -lt $script:EventsFallbackUntil) { $allow = $false }
        }
        if ($allow) {
            try {
                $all = Get-EventLog -LogName System -Newest 120 -ErrorAction SilentlyContinue
                $found = @($all | Where-Object { ([string]$_.Source) -eq 'W32Time' -or ([string]$_.Source) -match 'Time-Service' })
                $n = 0
                foreach ($e in $found) {
                    if ($n -ge $Max) { break }
                    $o = New-Object PSObject -Property @{ Time = $e.TimeGenerated; Id = $e.EventID; Source = [string]$e.Source; Message = [string]$e.Message }
                    [void]$out.Add($o)
                    $n = $n + 1
                }
                if ($out.Count -eq 0) { $script:EventsFallbackUntil = $nowT.AddMinutes(10) }
            } catch {
                $script:EventsFallbackUntil = $nowT.AddMinutes(10)
            }
        }
    }
    return $out
}

function Get-ConflictingServices {
    $res = New-Object System.Collections.ArrayList
    try {
        $svc = Get-WmiObject -Query "SELECT Name,DisplayName,State FROM Win32_Service WHERE Name LIKE '%ntp%'" -ErrorAction SilentlyContinue
        # Важно: в PowerShell 2.0 foreach по $null выполняет тело один раз с $null, поэтому пустой
        # ответ WMI давал «пустую службу» и ложное предупреждение о конфликте за порт 123.
        foreach ($s in @($svc)) {
            if ($s -eq $null) { continue }
            $nm = [string]$s.Name
            if ($nm -eq '' -or $nm -eq $script:SvcName) { continue }
            $o = New-Object PSObject -Property @{ Name = $nm; DisplayName = [string]$s.DisplayName; State = [string]$s.State }
            [void]$res.Add($o)
        }
    } catch { }
    return $res
}

# Домен/workgroup машины (кэшируется на сеанс): нужен, чтобы правильно объяснить, откуда
# может прийти групповая политика — из домена или только из локальной политики этой машины.
function Get-MachineDomainInfo {
    if ($script:DomainInfo -ne $null) { return $script:DomainInfo }
    $o = New-Object PSObject -Property @{ PartOfDomain = $false; Name = ''; Known = $false }
    try {
        $cs = Get-WmiObject Win32_ComputerSystem -ErrorAction SilentlyContinue
        if ($cs -ne $null) {
            $o.PartOfDomain = [bool]$cs.PartOfDomain
            $o.Name = [string]$cs.Domain
            $o.Known = $true
        }
    } catch { }
    $script:DomainInfo = $o
    return $o
}

# Настройки службы времени, заданные групповой политикой. Политика пишет значения
# в ветвь HKLM\SOFTWARE\Policies\Microsoft\W32Time\... (те же имена, что и у службы),
# и служба отдаёт предпочтение именно им, а не прямым ключам W32Time.
function Get-W32TimePolicyState {
    param([string]$Root = 'SOFTWARE\Policies\Microsoft\W32Time')
    $root = $Root
    $st = New-Object PSObject -Property @{ Exists = $false; Items = @(); Summary = '' }
    if (-not (Test-RegKeyExists $root)) { return $st }
    $st.Exists = $true
    $items = New-Object System.Collections.ArrayList
    $queue = New-Object System.Collections.ArrayList
    [void]$queue.Add($root)
    while ($queue.Count -gt 0) {
        $keyPath = [string]$queue[0]
        $queue.RemoveAt(0)
        $k = $null
        try {
            $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($keyPath, $false)
            if ($k -eq $null) { continue }
            foreach ($name in $k.GetValueNames()) {
                $val = $k.GetValue($name, $null)
                $short = $keyPath.Replace($root, '')
                if ($short -eq '') { $short = '\' }
                [void]$items.Add(($short.TrimStart('\') + '\' + $name + ' = ' + [string]$val).TrimStart('\'))
            }
            foreach ($sub in $k.GetSubKeyNames()) { [void]$queue.Add($keyPath + '\' + $sub) }
        } catch { } finally {
            if ($k -ne $null) { try { $k.Close() } catch { } }
        }
    }
    $st.Items = $items.ToArray()
    if ($items.Count -gt 0) { $st.Summary = ($items -join '; ') }
    return $st
}

# ---------------------------------------------------------------------------
# Строки состояния (общие для окна и текстового отчёта)
# ---------------------------------------------------------------------------
function New-StatusRow {
    param([string]$Item, [string]$Value, [string]$Verdict, [string]$Level = 'info')
    if ($script:Lang -eq 'en') {
        $Item = TPart (T $Item)
        $Value = TPart $Value
        $Verdict = TPart (T $Verdict)
    }
    return New-Object PSObject -Property @{ Item = $Item; Value = $Value; Verdict = $Verdict; Level = $Level }
}

function Get-StatusRows {
    param([switch]$RunSntpCheck, [int]$SntpTimeoutMs = 2500, $ExpectedServer = $null, $ExpectedClient = $null, [switch]$Fast)
    $rows = New-Object System.Collections.ArrayList
    $settings = Get-Settings
    $expectServer = ($settings['ExpectedServer'] -eq '1')
    $expectClient = ($settings['ExpectedClient'] -eq '1')
    if ($ExpectedServer -ne $null) { $expectServer = [bool]$ExpectedServer }
    if ($ExpectedClient -ne $null) { $expectClient = [bool]$ExpectedClient }
    $snap = Get-ServiceSnapshot -Fast:$Fast
    $st = Get-NtpConfigState
    # При быстром обновлении «медленные» проверки (брандмауэр, события, порт) берутся из кеша,
    # а в значение строки добавляется отметка времени, когда они реально выполнялись.
    $slowStamp = ''
    if ($Fast -and $script:SlowCache['SlowTime'] -ne $null) {
        $slowStamp = '   [проверено ' + ([datetime]$script:SlowCache['SlowTime']).ToString('HH:mm:ss') + ']'
    }

    # 1. Служба
    if (-not $snap.Exists) {
        if ($snap.RegisteredInRegistry) {
            [void]$rows.Add((New-StatusRow 'Служба w32time' 'нет в менеджере служб, но ключ службы в реестре есть' 'ВНИМАНИЕ: попробуйте перезагрузить сервер или нажать «Восстановить службу времени» на вкладке «Служба»' 'warn'))
        } else {
            [void]$rows.Add((New-StatusRow 'Служба w32time' 'не зарегистрирована в системе' 'ОШИБКА: именно поэтому её не видно в списке служб. Нажмите «Восстановить службу времени» на вкладке «Служба» (это w32tm /register)' 'err'))
        }
    } elseif ($snap.Status -ne 'Running') {
        [void]$rows.Add((New-StatusRow 'Служба w32time' $snap.StatusRu 'ОШИБКА: служба не работает' 'err'))
    } else {
        [void]$rows.Add((New-StatusRow 'Служба w32time' ($snap.StatusRu + ', PID ' + $snap.ProcessId) 'ОК' 'ok'))
    }
    # 2. Тип запуска
    if ($snap.StartModeRu -eq 'Автоматически') {
        [void]$rows.Add((New-StatusRow 'Тип запуска службы' $snap.StartModeRu 'ОК' 'ok'))
    } else {
        [void]$rows.Add((New-StatusRow 'Тип запуска службы' $snap.StartModeRu 'РЕКОМЕНДУЕТСЯ «Автоматически»' 'warn'))
    }
    # 3. Файл библиотеки
    if (-not $st.W32TimeDllExists) {
        [void]$rows.Add((New-StatusRow 'Файл w32time.dll' 'не найден' 'ОШИБКА: служба повреждена, нужен w32tm /register' 'err'))
    }
    # 4. Провайдер NTP-сервера
    $svcEnabled = ($null -ne $st.ServerEnabled -and [int]$st.ServerEnabled -eq 1)
    if ($expectServer) {
        if ($svcEnabled) { [void]$rows.Add((New-StatusRow 'NTP-сервер (раздача времени)' (Convert-BoolRu $st.ServerEnabled) 'ОК: отвечает клиентам' 'ok')) }
        else { [void]$rows.Add((New-StatusRow 'NTP-сервер (раздача времени)' (Convert-BoolRu $st.ServerEnabled) 'ОШИБКА: клиенты не получат время' 'err')) }
    } else {
        if ($svcEnabled) { [void]$rows.Add((New-StatusRow 'NTP-сервер (раздача времени)' (Convert-BoolRu $st.ServerEnabled) 'ВНИМАНИЕ: включён, хотя не требуется' 'warn')) }
        else { [void]$rows.Add((New-StatusRow 'NTP-сервер (раздача времени)' (Convert-BoolRu $st.ServerEnabled) 'ОК (не требуется)' 'ok')) }
    }
    # 5. Совместимость
    if ($svcEnabled) {
        if ($null -ne $st.AllowNonstandard -and [int]$st.AllowNonstandard -eq 1) {
            [void]$rows.Add((New-StatusRow 'AllowNonstandardModeCombinations' '1' 'ОК' 'ok'))
        } else {
            [void]$rows.Add((New-StatusRow 'AllowNonstandardModeCombinations' (Convert-BoolRu $st.AllowNonstandard) 'ВНИМАНИЕ: часть старых/нестандартных клиентов не получит время' 'warn'))
        }
    }
    # 6. Провайдер NTP-клиента
    $cliEnabled = ($null -ne $st.ClientEnabled -and [int]$st.ClientEnabled -eq 1)
    if ($expectClient) {
        if ($cliEnabled) { [void]$rows.Add((New-StatusRow 'NTP-клиент (получение времени)' (Convert-BoolRu $st.ClientEnabled) 'ОК' 'ok')) }
        else { [void]$rows.Add((New-StatusRow 'NTP-клиент (получение времени)' (Convert-BoolRu $st.ClientEnabled) 'ОШИБКА: машина не берёт время от GPS' 'err')) }
    } else {
        if ($cliEnabled) { [void]$rows.Add((New-StatusRow 'NTP-клиент (получение времени)' (Convert-BoolRu $st.ClientEnabled) 'ВНИМАНИЕ: включён, хотя не требуется' 'warn')) }
        else { [void]$rows.Add((New-StatusRow 'NTP-клиент (получение времени)' (Convert-BoolRu $st.ClientEnabled) 'ОК (не требуется)' 'ok')) }
    }
    # 7. Тип источника
    $typeVal = [string]$st.Type
    if ($typeVal -eq '') { $typeVal = 'не задано' }
    if ($expectClient) {
        if ([string]$st.Type -eq 'NTP') { [void]$rows.Add((New-StatusRow 'Параметры\Type (источник)' $typeVal 'ОК: ручной список серверов' 'ok')) }
        elseif ([string]$st.Type -eq 'NT5DS') { [void]$rows.Add((New-StatusRow 'Параметры\Type (источник)' $typeVal 'ВНИМАНИЕ: время берётся из иерархии домена, а не от GPS' 'warn')) }
        elseif ([string]$st.Type -eq 'NoSync') { [void]$rows.Add((New-StatusRow 'Параметры\Type (источник)' $typeVal 'ОШИБКА: синхронизация отключена' 'err')) }
        else { [void]$rows.Add((New-StatusRow 'Параметры\Type (источник)' $typeVal 'ВНИМАНИЕ: ожидается NTP' 'warn')) }
    } else {
        [void]$rows.Add((New-StatusRow 'Параметры\Type (источник)' $typeVal 'не контролируется' 'info'))
    }
    # 8. Список серверов времени
    $peersNorm = ''
    if ($st.Peers -ne $null) { $peersNorm = Get-PeerListNormalized ([string]$st.Peers) }
    $peers = @()
    if ($peersNorm -ne '') { $peers = @(Get-PeerHostsOnly $peersNorm) }
    if ($peers.Count -eq 0) {
        if ($expectClient) { [void]$rows.Add((New-StatusRow 'Список серверов времени' 'пусто' 'ОШИБКА: не указан GPS-сервер' 'err')) }
        else { [void]$rows.Add((New-StatusRow 'Список серверов времени' 'пусто' 'не требуется' 'info')) }
    } else {
        $badPeers = @($peers | Where-Object { $_ -notmatch '^[A-Za-z0-9\.\-_]+$' })
        if ($badPeers.Count -gt 0) {
            [void]$rows.Add((New-StatusRow 'Список серверов времени' $peersNorm ('ВНИМАНИЕ: проверьте запись ' + ($badPeers -join ', ')) 'warn'))
        } else {
            [void]$rows.Add((New-StatusRow 'Список серверов времени' $peersNorm ('ОК, источников: ' + $peers.Count) 'ok'))
        }
    }
    # 9. Интервал опроса
    if ($expectClient) {
        if ($st.SpecialPollInterval -eq $null) {
            [void]$rows.Add((New-StatusRow 'Интервал опроса (SpecialPollInterval)' 'не задано' 'ВНИМАНИЕ: будет использоваться 64–1024 с' 'warn'))
        } elseif ([int]$st.SpecialPollInterval -lt 32 -or [int]$st.SpecialPollInterval -gt 86400) {
            [void]$rows.Add((New-StatusRow 'Интервал опроса (SpecialPollInterval)' ([string]$st.SpecialPollInterval + ' с') 'ВНИМАНИЕ: нестандартное значение' 'warn'))
        } else {
            [void]$rows.Add((New-StatusRow 'Интервал опроса (SpecialPollInterval)' ([string]$st.SpecialPollInterval + ' с') 'ОК' 'ok'))
        }
    }
    # 10. AnnounceFlags
    $ann = $st.AnnounceFlags
    $annVal = 'не задано'
    if ($ann -ne $null) { $annVal = [string]$ann }
    if ($ann -ne $null -and [int]$ann -eq 5) {
        [void]$rows.Add((New-StatusRow 'AnnounceFlags (надёжность)' $annVal 'ОК: надёжный источник времени' 'ok'))
    } elseif ($expectServer -and $svcEnabled) {
        [void]$rows.Add((New-StatusRow 'AnnounceFlags (надёжность)' $annVal 'ВНИМАНИЕ: обычно для сервера ставят 5' 'warn'))
    } else {
        [void]$rows.Add((New-StatusRow 'AnnounceFlags (надёжность)' $annVal 'не контролируется' 'info'))
    }
    # 10b. Групповая политика службы времени: политика важнее прямых ключей реестра
    $pol = Get-W32TimePolicyState
    $dom = Get-MachineDomainInfo
    if ($pol.Exists -and $pol.Items.Count -gt 0) {
        [void]$rows.Add((New-StatusRow 'Групповая политика службы времени' $pol.Summary 'ВНИМАНИЕ: эти значения заданы политикой и перекрывают реестр службы. Правьте политику (gpedit.msc → Административные шаблоны → Система → Служба времени Windows) или переведите её в «Не задано», иначе изменения утилиты будут отменены' 'warn'))
    } else {
        $domTxt = ''
        if ($dom.Known) {
            if ($dom.PartOfDomain) { $domTxt = ' Машина в домене ' + $dom.Name + ': политику может задать и контроллер домена.' }
            else { $domTxt = ' Машина не в домене (' + $dom.Name + '): политика может прийти только из локальной групповой политики.' }
        }
        [void]$rows.Add((New-StatusRow 'Групповая политика службы времени' 'политик не найдено' ('ОК: параметры задаются напрямую и ничего их не перекрывает.' + $domTxt) 'ok'))
    }
    # 11. Слушатели UDP 123. Владелец порта определяется по PID службы времени ИЛИ по тому,
    # живёт ли служба w32time внутри процесса-слушателя: служба работает внутри svchost,
    # поэтому «svchost» в списке — это норма, а не конфликт.
    $needPortCheck = $false
    if (-not $Fast) { $needPortCheck = $true }
    elseif ($script:SlowCache['Listeners'] -eq $null) { $needPortCheck = $true }
    elseif ($script:SlowCache['PortForeign'] -eq $true) { $needPortCheck = $true }
    elseif ([string]$script:SlowCache['SvcStateAtCheck'] -ne [string]$snap.Status) { $needPortCheck = $true }
    if ($needPortCheck) {
        $script:SlowCache['Listeners'] = @(Get-UdpListeners $script:NtpPort)
        $script:SlowCache['SlowTime'] = Get-Date
        $script:SlowCache['SvcStateAtCheck'] = [string]$snap.Status
        if (-not $Fast) {
            $script:SlowCache['SvcPid'] = $snap.ProcessId
        } elseif ([int]$script:SlowCache['SvcPid'] -le 0) {
            # в быстром режиме PID берётся точечно и только когда это действительно нужно
            try {
                $wsvc = Get-WmiObject Win32_Service -Filter ("Name='" + $script:SvcName + "'") -ErrorAction SilentlyContinue
                if ($wsvc -ne $null) { $script:SlowCache['SvcPid'] = [int]$wsvc.ProcessId }
            } catch { }
        }
    }
    $listeners = @()
    # В PowerShell 2.0 @($null) даёт массив из одного пустого элемента, поэтому элементы
    # фильтруются явно — иначе пустой порт выглядел бы как «посторонний процесс».
    foreach ($l0 in @($script:SlowCache['Listeners'])) { if ($l0 -ne $null) { $listeners += $l0 } }
    $w32Pid = [int]$script:SlowCache['SvcPid']
    $foreignName = ''
    $ownName = ''
    $foreign = $false
    if ($listeners.Count -eq 0) {
        if ($svcEnabled -and $snap.Status -eq 'Running') {
            [void]$rows.Add((New-StatusRow ('Порт UDP ' + $script:NtpPort) 'никто не слушает' 'ОШИБКА: NTP-сервер не запущен фактически' 'err'))
        } else {
            [void]$rows.Add((New-StatusRow ('Порт UDP ' + $script:NtpPort) 'никто не слушает' 'ОК (раздача выключена)' 'ok'))
        }
    } else {
        $strs = New-Object System.Collections.ArrayList
        foreach ($l in $listeners) {
            $tag = 'PID ' + $l.ProcessId
            if ($l.Process -ne '') { $tag = $tag + ' (' + $l.Process + ')' }
            $isOurs = $false
            if ($w32Pid -gt 0 -and $l.ProcessId -eq $w32Pid) { $isOurs = $true }
            if (-not $isOurs -and $l.ProcessId -ne 0) {
                $svcNames = @(Get-ServicesInProcess $l.ProcessId)
                if ($svcNames -contains $script:SvcName) { $isOurs = $true }
            }
            if ($isOurs) {
                $tag = $tag + ' = служба времени'
                if ($ownName -eq '') { $ownName = [string]$l.Process }
            } else {
                if ($l.ProcessId -ne 0) {
                    $foreign = $true
                    if ($l.Process -ne '') { $foreignName = $l.Process }
                }
            }
            [void]$strs.Add(('[' + $l.Address + ']:' + $l.Port + ' ' + $tag))
        }
        $val = ($strs -join '; ') + $slowStamp
        if ($foreign) {
            $verdict = 'ВНИМАНИЕ: порт слушает посторонний процесс'
            if ($foreignName -ne '') { $verdict = $verdict + ' (' + $foreignName + ')' }
            $verdict = $verdict + ' — служба времени Windows не сможет принимать запросы. Остановите или удалите сторонний NTP-сервис либо не включайте раздачу времени средствами Windows'
            [void]$rows.Add((New-StatusRow ('Порт UDP ' + $script:NtpPort) $val $verdict 'warn'))
        } else {
            [void]$rows.Add((New-StatusRow ('Порт UDP ' + $script:NtpPort) $val 'ОК' 'ok'))
            if ($ownName -eq 'svchost') {
                [void]$rows.Add((New-StatusRow 'Как работает служба времени' 'внутри процесса svchost.exe' 'Так и должно быть: отдельного процесса w32time в системе нет — служба живёт в общем процессе-хосте. «svchost» в строке выше — это она и есть, конфликта нет.' 'info'))
            }
        }
    }
    $script:SlowCache['PortForeign'] = $foreign
    # 12. Брандмауэр (медленная проверка — из кеша при быстром обновлении)
    if (-not $Fast -or $script:SlowCache['FwInfo'] -eq $null) {
        $script:SlowCache['FwInfo'] = Get-NtpFirewallRuleInfo
        $script:SlowCache['FwProfiles'] = Get-FirewallProfilesEnabled
        $script:SlowCache['SlowTime'] = Get-Date
    }
    $fw = $script:SlowCache['FwInfo']
    $fwProf = $script:SlowCache['FwProfiles']
    $fwStateStr = 'домен:' + (Convert-BoolRu $fwProf.DomainProfile) + ', частный:' + (Convert-BoolRu $fwProf.StandardProfile) + ', общий:' + (Convert-BoolRu $fwProf.PublicProfile)
    [void]$rows.Add((New-StatusRow 'Брандмауэр (профили)' ($fwStateStr + $slowStamp) 'справочно' 'info'))
    if (-not $fw.Checked) {
        [void]$rows.Add((New-StatusRow 'Правило брандмауэра для UDP 123' 'не удалось проверить' 'ВНИМАНИЕ: нужны права администратора' 'warn'))
    } elseif ($fw.Exists) {
        [void]$rows.Add((New-StatusRow 'Правило брандмауэра для UDP 123' ('есть: ' + $script:FwRuleName + $slowStamp) 'ОК' 'ok'))
    } elseif ($fwProf.AnyEnabled) {
        [void]$rows.Add((New-StatusRow 'Правило брандмауэра для UDP 123' ('не найдено' + $slowStamp) 'ВНИМАНИЕ: брандмауэр включён, клиенты могут не получить время' 'warn'))
    } else {
        [void]$rows.Add((New-StatusRow 'Правило брандмауэра для UDP 123' ('не найдено' + $slowStamp) 'ОК (брандмауэр выключен)' 'ok'))
    }
    # 13. Конфликтующие службы (из кеша при быстром обновлении)
    if (-not $Fast -or $script:SlowCache['Conflicts'] -eq $null) {
        $script:SlowCache['Conflicts'] = @(Get-ConflictingServices)
    }
    $conf = @()
    foreach ($c0 in @($script:SlowCache['Conflicts'])) { if ($c0 -ne $null) { $conf += $c0 } }
    if ($conf.Count -gt 0) {
        $names = New-Object System.Collections.ArrayList
        foreach ($c in $conf) { [void]$names.Add($c.Name + ' [' + $c.State + ']') }
        [void]$rows.Add((New-StatusRow 'Другие NTP-службы' (($names -join ', ') + $slowStamp) 'ВНИМАНИЕ: возможен конфликт за порт 123' 'warn'))
    } else {
        [void]$rows.Add((New-StatusRow 'Другие NTP-службы' ('не обнаружены' + $slowStamp) 'ОК' 'ok'))
    }
    # 14. Последнее событие службы времени (из кеша при быстром обновлении)
    if (-not $Fast -or $script:SlowCache['Events'] -eq $null) {
        $script:SlowCache['Events'] = @(Get-W32TimeEvents -Max 1)
    }
    $events = @()
    foreach ($ev0 in @($script:SlowCache['Events'])) { if ($ev0 -ne $null) { $events += $ev0 } }
    if ($events.Count -gt 0 -and $events[0] -ne $null -and $events[0].Time -ne $null) {
        $e0 = $events[0]
        [void]$rows.Add((New-StatusRow 'Последнее событие W32Time' ($e0.Time.ToString('yyyy-MM-dd HH:mm:ss') + ' (ID ' + $e0.Id + ')' + $slowStamp) 'справочно' 'info'))
    } else {
        [void]$rows.Add((New-StatusRow 'Последнее событие W32Time' ('нет записей в журнале System' + $slowStamp) 'справочно' 'info'))
    }
    # 15. Проверка отклика локального сервера (SNTP, а при недоступности - через w32tm)
    if (-not (Test-SntpStack)) {
        [void]$rows.Add((New-StatusRow 'Проверка встроенным SNTP-клиентом' 'недоступна в этом сеансе PowerShell' ('Используется резервная проверка через w32tm. Причина: ' + $script:SntpStackError) 'info'))
    }
    if ($RunSntpCheck -and -not $Fast) {
        $script:SntpLocal = Invoke-NtpCheck -Server '127.0.0.1' -Samples 1 -TimeoutMs $SntpTimeoutMs
    }
    if ($script:SntpLocal -ne $null) {
        $q = $script:SntpLocal
        if ($q.Success) {
            if ($q.Source -eq 'sntp') {
                $val = 'stratum ' + $q.Stratum + ', источник ' + $q.RefId + ', смещение ' + [Math]::Round($q.OffsetMs, 1) + ' мс, задержка ' + [Math]::Round($q.DelayMs, 1) + ' мс'
            } else {
                $val = 'отвечает (резервная проверка w32tm), задержка ' + [Math]::Round($q.DelayMs, 3) + ' мс, смещение o: ' + [Math]::Round($q.OffsetMs, 3) + ' мс'
            }
            if ($q.Unsynchronized) {
                [void]$rows.Add((New-StatusRow 'Отклик 127.0.0.1:123' $val 'ВНИМАНИЕ: сервер отвечает, но сам не синхронизирован (LI=3 / stratum 16)' 'warn'))
            } elseif ($foreignName -ne '') {
                [void]$rows.Add((New-StatusRow 'Отклик 127.0.0.1:123' $val ('ВНИМАНИЕ: на порту 123 отвечает посторонний процесс (' + $foreignName + '), а не служба времени Windows — ответ мог дать он') 'warn'))
            } else {
                [void]$rows.Add((New-StatusRow 'Отклик 127.0.0.1:123' $val 'ОК' 'ok'))
            }
        } else {
            [void]$rows.Add((New-StatusRow 'Отклик 127.0.0.1:123' 'нет ответа' ('ОШИБКА: ' + $q.Error) 'err'))
        }
    }
    # 16. Проверка GPS-сервера
    if ($RunSntpCheck -and -not $Fast -and $peers.Count -gt 0) {
        $script:SntpPeer = Invoke-NtpCheck -Server $peers[0] -Samples 1 -TimeoutMs $SntpTimeoutMs
        $script:SntpPeerServer = $peers[0]
    }
    if ($script:SntpPeer -ne $null) {
        $q = $script:SntpPeer
        $name = [string]$script:SntpPeerServer
        if ($q.Success) {
            if ($q.Source -eq 'sntp') {
                $val = 'stratum ' + $q.Stratum + ', источник ' + $q.RefId + ', смещение ' + [Math]::Round($q.OffsetMs, 1) + ' мс, задержка ' + [Math]::Round($q.DelayMs, 1) + ' мс'
            } else {
                $val = 'отвечает (резервная проверка w32tm), задержка ' + [Math]::Round($q.DelayMs, 3) + ' мс, смещение o: ' + [Math]::Round($q.OffsetMs, 3) + ' мс'
            }
            if ($q.Unsynchronized) {
                [void]$rows.Add((New-StatusRow ('Сервер времени ' + $name) $val 'ВНИМАНИЕ: отвечает, но не синхронизирован (нет привязки к GPS)' 'warn'))
            } elseif ([Math]::Abs([double]$q.OffsetMs) -gt 1000) {
                [void]$rows.Add((New-StatusRow ('Сервер времени ' + $name) $val 'ВНИМАНИЕ: большое расхождение часов' 'warn'))
            } else {
                [void]$rows.Add((New-StatusRow ('Сервер времени ' + $name) $val 'ОК' 'ok'))
            }
        } else {
            [void]$rows.Add((New-StatusRow ('Сервер времени ' + $name) 'нет ответа' ('ОШИБКА: ' + $q.Error) 'err'))
        }
    }
    return $rows
}

function Get-StatusSummary {
    param($Rows)
    $err = 0; $warn = 0; $ok = 0
    foreach ($r in $Rows) {
        if ($r.Level -eq 'err') { $err = $err + 1 }
        elseif ($r.Level -eq 'warn') { $warn = $warn + 1 }
        elseif ($r.Level -eq 'ok') { $ok = $ok + 1 }
    }
    $s = New-Object PSObject -Property @{ Errors = $err; Warnings = $warn; Ok = $ok; Total = $Rows.Count; Text = ''; Level = 'info'; Code = 0 }
    if ($err -gt 0) { $s.Text = ('Есть ошибки: ' + $err); $s.Level = 'err'; $s.Code = 2 }
    elseif ($warn -gt 0) { $s.Text = ('Замечания: ' + $warn); $s.Level = 'warn'; $s.Code = 1 }
    else { $s.Text = 'Всё в норме'; $s.Level = 'ok'; $s.Code = 0 }
    return $s
}

function Get-TextReport {
    param($Rows = $null, $Summary = $null, [switch]$RunSntpCheck, [int]$SntpTimeoutMs = 2500)
    if ($Rows -eq $null) { $Rows = Get-StatusRows -RunSntpCheck:$RunSntpCheck -SntpTimeoutMs $SntpTimeoutMs }
    if ($Summary -eq $null) { $Summary = Get-StatusSummary $Rows }
    $sum = $Summary
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('=============================================================')
    [void]$sb.AppendLine(' NTP Manager ' + $script:Ver + ' — отчёт о состоянии')
    [void]$sb.AppendLine(' Компьютер : ' + (Get-MachineName))
    [void]$sb.AppendLine(' Время     : ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
    [void]$sb.AppendLine(' ОС        : ' + [System.Environment]::OSVersion.VersionString)
    [void]$sb.AppendLine(' PowerShell: ' + $PSVersionTable.PSVersion.ToString())
    [void]$sb.AppendLine(' Права     : ' + $(if ($script:IsAdmin) { 'администратор' } else { 'обычный пользователь' }))
    [void]$sb.AppendLine(' Итог      : ' + $sum.Text)
    [void]$sb.AppendLine('=============================================================')
    foreach ($r in $rows) {
        $mark = '  '
        if ($r.Level -eq 'ok') { $mark = 'OK' }
        elseif ($r.Level -eq 'warn') { $mark = '!!' }
        elseif ($r.Level -eq 'err') { $mark = 'XX' }
        elseif ($r.Level -eq 'info') { $mark = '--' }
        [void]$sb.AppendLine('[' + $mark + '] ' + $r.Item)
        [void]$sb.AppendLine('      ' + $r.Value)
        [void]$sb.AppendLine('      ' + $r.Verdict)
    }
    [void]$sb.AppendLine('-------------------------------------------------------------')
    [void]$sb.AppendLine(' Вывод w32tm /query /status:')
    $r1 = Invoke-W32tm -Arguments '/query /status' -TimeoutSec 60
    [void]$sb.AppendLine(' ' + (Get-ExeText $r1 -WithErrors))
    [void]$sb.AppendLine('-------------------------------------------------------------')
    [void]$sb.AppendLine(' Вывод w32tm /query /configuration (первые 60 строк):')
    $r2 = Invoke-W32tm -Arguments '/query /configuration' -TimeoutSec 60
    $lines = @((Get-ExeText $r2 -WithErrors) -split "`r?`n")
    $n = 0
    foreach ($l in $lines) {
        if ($n -ge 60) { [void]$sb.AppendLine(' ... (обрезано)'); break }
        [void]$sb.AppendLine(' ' + $l)
        $n = $n + 1
    }
    return $sb.ToString()
}

# ---------------------------------------------------------------------------
# Режимы командной строки
# ---------------------------------------------------------------------------
function Show-HelpText {
    Write-Cli ''
    Write-Cli ('NtpManager ' + $script:Ver + ' — мониторинг и управление NTP на Windows Server 2008 R2') 'Cyan'
    Write-Cli ''
    Write-Cli 'Запуск без ключей        — графический интерфейс (права администратора запрашиваются сами).'
    Write-Cli 'Ключ -Report             — текстовая проверка состояния, ничего не меняет, без прав администратора.'
    Write-Cli '                           Код возврата: 0 — норма, 1 — замечания, 2 — ошибки.'
    Write-Cli 'Ключ -Apply              — применить настройки (нужны права администратора) вместе с:'
    Write-Cli '   -ServerList "192.168.1.50,0x9"   список серверов времени (GPS), через пробел для нескольких'
    Write-Cli '   -TimeSourceType NTP              NTP | NT5DS | NoSync'
    Write-Cli '   -PollInterval 300                интервал опроса, секунды'
    Write-Cli '   -EnableServer | -DisableServer   включить/выключить раздачу времени клиентам'
    Write-Cli '   -EnableClient | -DisableClient   включить/выключить получение времени'
    Write-Cli '   -Reliable | -NotReliable         помечать ли машину надёжным источником (AnnounceFlags)'
    Write-Cli '   -OpenFirewall | -RemoveFirewall  разрешить/закрыть входящий UDP 123 в брандмауэре'
    Write-Cli '   -StartupMode Auto                Auto | Manual | Disabled'
    Write-Cli '   -MaxAllowedPhaseOffset 3600      порог исправления смещения, секунды'
    Write-Cli '   -EventLogFlags 2                 подробность журнала событий службы'
    Write-Cli '   -NoRestart                       не перезапускать службу после записи настроек'
    Write-Cli 'Ключ -RestoreService     — зарегистрировать службу времени заново (w32tm /register), когда её не видно в списке служб.'
    Write-Cli 'Ключ -Apply -UsePolicyBranch — дополнительно записать параметры в ветвь групповой политики.'
    Write-Cli 'Ключ -Language en|ru        — язык интерфейса и отчёта (ru | en).'
    Write-Cli 'Ключ -Help               — эта справка.'
    Write-Cli ''
    Write-Cli 'Примеры:'
    Write-Cli '  NtpManager.cmd -Report'
    Write-Cli '  NtpManager.cmd -Apply -ServerList "192.168.1.50,0x9" -EnableServer -EnableClient -Reliable -PollInterval 300 -OpenFirewall'
    Write-Cli ''
    Write-Cli ('Файлы: настройки — ' + $script:SettingsFile)
    Write-Cli ('Журнал : ' + $script:LogFile)
    Write-Cli ('Резервные копии — ' + $script:BackupDir)
    Write-Cli ''
}

function Invoke-ReportMode {
    param([string]$ReportFile = '')
    $rows = Get-StatusRows -RunSntpCheck
    $sum = Get-StatusSummary $rows
    if ($ReportFile -ne '') {
        try {
            $text = TPart (Get-TextReport -Rows $rows -Summary $sum)
            [System.IO.File]::WriteAllText($ReportFile, $text, (New-Object System.Text.UTF8Encoding($true)))
            Write-Cli ('Полный текстовый отчёт записан в файл: ' + $ReportFile) 'Green'
        } catch {
            Write-Cli ('Не удалось записать отчёт в файл: ' + $_.Exception.Message) 'Red'
        }
    }
    Write-Cli ''
    Write-Cli ('=== NTP Manager ' + $script:Ver + ' — отчёт о состоянии (' + (Get-MachineName) + ') ===') 'Cyan'
    foreach ($r in $rows) {
        $color = 'Gray'
        if ($r.Level -eq 'ok') { $color = 'Green' }
        elseif ($r.Level -eq 'warn') { $color = 'Yellow' }
        elseif ($r.Level -eq 'err') { $color = 'Red' }
        Write-Cli ('  ' + $r.Item + ': ' + $r.Value) $color
        Write-Cli ('      ' + $r.Verdict) $color
    }
    Write-Cli ''
    $color = 'Green'
    if ($sum.Level -eq 'warn') { $color = 'Yellow' }
    if ($sum.Level -eq 'err') { $color = 'Red' }
    Write-Cli ('ИТОГ: ' + $sum.Text + ' (ок: ' + $sum.Ok + ', замечаний: ' + $sum.Warnings + ', ошибок: ' + $sum.Errors + ')') $color
    Write-Cli ('Код возврата: ' + $sum.Code + ' (0 — всё в норме, 1 — замечания, 2 — ошибки)') $color
    Write-Cli ''
    Write-Cli 'Вывод w32tm /query /status:'
    $r1 = Invoke-W32tm -Arguments '/query /status' -TimeoutSec 60
    Write-Cli (Get-ExeText $r1 -WithErrors)
    Write-Cli ''
    return $sum.Code
}

function Invoke-RestoreMode {
    if (-not $script:IsAdmin) {
        Write-Cli 'ОШИБКА: для восстановления службы нужны права администратора.' 'Red'
        return 2
    }
    Write-Cli 'Восстанавливаю регистрацию службы времени (w32tm /register)...' 'Cyan'
    $log = Register-TimeService
    foreach ($l in $log) { Write-Cli ('  ' + $l) }
    $snap = Get-ServiceSnapshot
    if ($snap.Exists -and [string]$snap.Status -eq 'Running') {
        Write-Cli 'Служба времени зарегистрирована и работает.' 'Green'
        return (Invoke-ReportMode)
    }
    Write-Cli 'Служба по-прежнему не видна в списке служб. Проверьте %windir%\system32\w32time.dll (sfc /scannow) и журнал утилиты.' 'Red'
    return 2
}

function Invoke-ApplyMode {
    if (-not $script:IsAdmin) {
        Write-Cli 'ОШИБКА: для применения настроек нужны права администратора.' 'Red'
        Write-Cli 'Запустите окно утилиты двойным щелчком по NtpManager.cmd — оно запросит повышение прав само,' 'Yellow'
        Write-Cli 'или запустите командную строку от имени администратора.' 'Yellow'
        return 2
    }
    $o = @{}
    if ($ServerList -ne '') { $o['Peers'] = $ServerList }
    if ($TimeSourceType -ne '') { $o['Type'] = $TimeSourceType }
    if ($PollInterval -gt 0) { $o['PollInterval'] = $PollInterval }
    if ($StartupMode -ne '') { $o['StartupMode'] = $StartupMode }
    if ($EnableServer) { $o['ServerEnabled'] = 1 }
    if ($DisableServer) { $o['ServerEnabled'] = 0 }
    if ($EnableClient) { $o['ClientEnabled'] = 1 }
    if ($DisableClient) { $o['ClientEnabled'] = 0 }
    if ($Reliable) { $o['Reliable'] = $true }
    if ($NotReliable) { $o['Reliable'] = $false }
    if ($MaxAllowedPhaseOffset -ge 0) { $o['MaxAllowedPhaseOffset'] = $MaxAllowedPhaseOffset }
    if ($EventLogFlags -ge 0) { $o['EventLogFlags'] = $EventLogFlags }
    if ($OpenFirewall) { $o['AddFirewall'] = $true }
    if ($UsePolicyBranch) { $o['UsePolicyBranch'] = $true }
    if ($RemoveFirewall) { $o['RemoveFirewall'] = $true }
    if ($o.ContainsKey('ServerEnabled') -and $o['ServerEnabled'] -eq 1 -and -not $o.ContainsKey('AllowNonstandard')) { $o['AllowNonstandard'] = 1 }
    if ($NoRestart) { $o['Restart'] = $false }

    if ($o.Keys.Count -eq 0) {
        Write-Cli 'Не указано ни одного изменения. Пример:' 'Yellow'
        Write-Cli '  NtpManager.cmd -Apply -ServerList "192.168.1.50,0x9" -EnableServer -EnableClient -Reliable -PollInterval 300 -OpenFirewall'
        return 1
    }

    Write-Cli ''
    Write-Cli 'Планируемые изменения:' 'Cyan'
    $preview = Set-NtpConfiguration -Options $o -Preview
    if ($preview.Count -eq 0) { Write-Cli '  (изменений не требуется — настройки уже такие)' }
    foreach ($c in $preview) { Write-Cli ('  - ' + $c) }
    Write-Cli ''
    Write-Cli 'Применяю...' 'Cyan'
    try {
        $applied = Set-NtpConfiguration -Options $o
    } catch {
        Write-Cli ('ОШИБКА: ' + $_.Exception.Message) 'Red'
        return 2
    }
    if ($script:LastApplyErrors -ne $null -and $script:LastApplyErrors.Count -gt 0) {
        Write-Cli ''
        Write-Cli 'При применении были ошибки:' 'Red'
        foreach ($e in $script:LastApplyErrors) { Write-Cli ('  - ' + $e) 'Red' }
    } else {
        Write-Cli 'Готово.' 'Green'
    }
    # сохраняем использованные значения в ini, чтобы окно их показало
    $s = Get-Settings
    if ($o.ContainsKey('Peers')) { $s['ServerList'] = [string]$o['Peers'] }
    if ($o.ContainsKey('PollInterval')) { $s['PollInterval'] = [string]$o['PollInterval'] }
    if ($o.ContainsKey('Type')) { $s['Type'] = [string]$o['Type'] }
    if ($o.ContainsKey('ServerEnabled')) { $s['EnableServer'] = [string]$o['ServerEnabled'] }
    if ($o.ContainsKey('ClientEnabled')) { $s['EnableClient'] = [string]$o['ClientEnabled'] }
    if ($o.ContainsKey('Reliable')) { $s['Reliable'] = '1' ; if ($o['Reliable'] -ne $true) { $s['Reliable'] = '0' } }
    if ($o.ContainsKey('StartupMode')) { $s['StartupMode'] = [string]$o['StartupMode'] }
    if ($o.ContainsKey('AddFirewall')) { $s['AddFirewall'] = '1' }
    if ($o.ContainsKey('MaxAllowedPhaseOffset')) { $s['MaxAllowedPhaseOffset'] = [string]$o['MaxAllowedPhaseOffset'] }
    if ($o.ContainsKey('EventLogFlags')) { $s['EventLogFlags'] = [string]$o['EventLogFlags'] }
    [void](Save-Settings -Settings $s)
    Write-Cli ''
    return (Invoke-ReportMode)
}

# ---------------------------------------------------------------------------
# Графический интерфейс
# ---------------------------------------------------------------------------
function Add-WinForms {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
}

function New-MonoFont {
    param([double]$Size = 9)
    try { return (New-Object System.Drawing.Font('Consolas', $Size)) } catch { return (New-Object System.Drawing.Font('Courier New', $Size)) }
}

function New-UiLabel {
    param($Parent, [string]$Text, [int]$X, [int]$Y, [int]$W = 0, [int]$H = 18)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = (T $Text)
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    if ($W -gt 0) { $l.Width = $W }
    $l.Height = $H
    [void]$Parent.Controls.Add($l)
    return $l
}

function New-UiButton {
    param($Parent, [string]$Text, [int]$X, [int]$Y, [int]$W = 120, [int]$H = 26)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = (T $Text)
    $b.Location = New-Object System.Drawing.Point($X, $Y)
    $b.Size = New-Object System.Drawing.Size($W, $H)
    [void]$Parent.Controls.Add($b)
    return $b
}

function New-UiCheck {
    param($Parent, [string]$Text, [int]$X, [int]$Y, [int]$W = 400)
    $c = New-Object System.Windows.Forms.CheckBox
    $c.Text = (T $Text)
    $c.Location = New-Object System.Drawing.Point($X, $Y)
    $c.Width = $W
    [void]$Parent.Controls.Add($c)
    return $c
}

function New-UiGroup {
    param($Parent, [string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H)
    $g = New-Object System.Windows.Forms.GroupBox
    $g.Text = (T $Text)
    $g.Location = New-Object System.Drawing.Point($X, $Y)
    $g.Size = New-Object System.Drawing.Size($W, $H)
    [void]$Parent.Controls.Add($g)
    return $g
}

function New-UiTabPage {
    param($Parent, [string]$Text)
    $p = New-Object System.Windows.Forms.TabPage
    $p.Text = (T $Text)
    $p.AutoScroll = $true
    [void]$Parent.Controls.Add($p)
    return $p
}

function Set-OutputText {
    param([string]$Text, [switch]$Append)
    $box = $script:Ui['OutBox']
    if ($box -eq $null) { return }
    if (-not $Append) { $box.Clear() }
    $box.AppendText((TPart $Text) + [Environment]::NewLine)
    $box.SelectionStart = $box.TextLength
    $box.ScrollToCaret()
}

function Set-PreviewText {
    param($Lines)
    $box = $script:Ui['PrevBox']
    if ($box -eq $null) { return }
    $box.Clear()
    if ($Lines -eq $null -or $Lines.Count -eq 0) {
        $box.AppendText('Изменений не требуется — настройки уже такие.' + [Environment]::NewLine)
        return
    }
    foreach ($l in $Lines) { $box.AppendText('• ' + (TPart $l) + [Environment]::NewLine) }
}

function Show-Info {
    param([string]$Text, [string]$Title = 'NTP Manager')
    [void][System.Windows.Forms.MessageBox]::Show((TPart $Text), $Title, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
}

function Show-Error {
    param([string]$Text, [string]$Title = 'NTP Manager')
    [void][System.Windows.Forms.MessageBox]::Show((TPart $Text), $Title, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
}

function Ask-Confirm {
    param([string]$Text, [string]$Title = 'NTP Manager')
    $r = [System.Windows.Forms.MessageBox]::Show((TPart $Text), $Title, [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    return ($r -eq [System.Windows.Forms.DialogResult]::Yes)
}

function Parse-IntOrNull {
    param([string]$Text)
    if ($Text -eq $null) { return $null }
    $t = $Text.Trim()
    if ($t -eq '') { return $null }
    if ($t -match '^-?[0-9]+$') { return [int]$t }
    return $null
}

function Set-UiTip {
    param($Control, [string]$Text)
    if ($script:Ui['Tip'] -eq $null) { return }
    if ($Control -eq $null) { return }
    try { $script:Ui['Tip'].SetToolTip($Control, (T $Text)) } catch { }
}

# Справка по каждому элементу окна (видна при наведении курсора).
function Set-AllUiTips {
    Set-UiTip $script:Ui['StatusList'] 'Строки состояния: OK — норма, !! — замечание, XX — ошибка, «--» — справочно. У строк, взятых из кеша, показано время, когда проверка выполнялась.'
    Set-UiTip $script:Ui['CmbStartup'] 'Тип запуска службы времени. Для сервера времени нужен «Автоматически».'
    Set-UiTip $script:Ui['ChkAutoRefresh'] 'Периодически обновлять состояние. Обновление «лёгкое» — только служба и параметры реестра, без опроса серверов и чтения журнала, поэтому окно не подвисает.'
    Set-UiTip $script:Ui['NumRefresh'] 'Период автообновления в секундах (5–600). Полная проверка (брандмауэр, события, порт) выполняется автоматически раз в 10 минут или по кнопке «Обновить».'
    Set-UiTip $script:Ui['ChkNotify'] 'Показывать всплывающее уведомление, если служба времени остановилась или запустилась.'
    Set-UiTip $script:Ui['ChkMonitorSntp'] 'Раз в 5 минут опрашивать свой NTP-сервер и проверять, что он отвечает. Опрос занимает до 1–3 секунд и может кратковременно «подвесить» окно — поэтому по умолчанию выключено.'
    Set-UiTip $script:Ui['ChkTray'] 'Показывать значок в области уведомлений с текущим состоянием службы времени.'
    Set-UiTip $script:Ui['ChkMinToTray'] 'При закрытии окна утилита останется в области уведомлений и продолжит мониторинг.'
    Set-UiTip $script:Ui['ChkExpectedServer'] 'Что считать нормой: если галочка снята, выключенная раздача времени не будет считаться ошибкой.'
    Set-UiTip $script:Ui['ChkExpectedClient'] 'Что считать нормой: если галочка снята, отсутствие получения времени не будет считаться ошибкой.'
    Set-UiTip $script:Ui['ChkServer'] 'Разрешает этому компьютеру отдавать время по NTP (встроенный провайдер NtpServer). Без этого клиенты локальной сети не получат время. Нужен открытый входящий UDP 123.'
    Set-UiTip $script:Ui['ChkAllowNonstd'] 'AllowNonstandardModeCombinations = 1: отвечать и тем клиентам, кто обращается не строго по RFC (старые системы, часть промышленных контроллеров, аппаратные часы). Обычно можно включить.'
    Set-UiTip $script:Ui['ChkReliable'] 'Помечает компьютер надёжным источником времени (реестр Config\AnnounceFlags = 5; то же делает w32tm /config /reliable:yes). 10 — обычный участник домена.'
    Set-UiTip $script:Ui['ChkClient'] 'Включает получение времени от указанного ниже сервера (провайдер NtpClient). Если выключить, компьютер будет только отдавать время.'
    Set-UiTip $script:Ui['RadNtp'] 'Type = NTP: брать время из списка адресов ниже. Это нужный вариант для GPS-сервера в локальной сети.'
    Set-UiTip $script:Ui['RadNt5ds'] 'Type = NT5DS: брать время из иерархии Active Directory. Не подходит, если время должно идти от GPS.'
    Set-UiTip $script:Ui['RadNoSync'] 'Type = NoSync: ни с кем не синхронизироваться. Часы будут «плыть» — только для отладки.'
    Set-UiTip $script:Ui['TxtPeers'] 'Адрес GPS-сервера времени. Можно указать только IP — при включённой галочке утилита сама допишет ,0x9. Несколько адресов разделяются пробелом: 192.168.1.50,0x9 192.168.1.51,0x9'
    Set-UiTip $script:Ui['ChkPeerFlag'] 'Флаг 0x9 = 0x1 (использовать заданный интервал опроса) + 0x8 (режим клиента). Без флага служба опрашивает источник по своему расписанию (64–1024 с) и поле «Интервал опроса» не действует.'
    Set-UiTip $script:Ui['NumPoll'] 'SpecialPollInterval: как часто опрашивать GPS-сервер, секунды. В локальной сети достаточно 60–900; Microsoft рекомендует не больше 3600. Действует только при флаге 0x1/0x9 в адресе.'
    Set-UiTip $script:Ui['CmbStartupCfg'] 'Автоматически — служба времени стартует при загрузке сервера (так нужно для сервера времени). Вручную/Отключена — обычно только для отладки.'
    Set-UiTip $script:Ui['ChkFirewall'] 'Создаёт правило входящего UDP 123 в брандмауэре Windows («NTP Server UDP 123 (NtpManager)»). Без него клиенты не получат время, даже если служба работает.'
    Set-UiTip $script:Ui['TxtPhase'] 'MaxAllowedPhaseOffset, секунды: если расхождение часов больше этого значения, служба не станет догонять время разом, а запишет ошибку. Пусто — не менять. По умолчанию 300; при сильно ушедших часах ставят 3600.'
    Set-UiTip $script:Ui['TxtEvents'] 'EventLogFlags: подробность записей службы в журнале System. 0 — минимум, 1 — важные события, 2 — также изменения времени, 3 — подробно. Пусто — не менять; для диагностики 2–3.'
    Set-UiTip $script:Ui['PrevBox'] 'Точный список изменений, которые будут внесены. Кнопка «Проверить изменения» ничего не меняет в системе.'
    Set-UiTip $script:Ui['TxtCheckServer'] 'Адрес сервера для проверки. С клиентской машины укажите адрес этого сервера — так проверится сквозная доступность вместе с брандмауэром.'
    Set-UiTip $script:Ui['OutBox'] 'Вывод команд и результаты проверок. Можно сохранить в файл или скопировать.'
    Set-UiTip $script:Ui['LogBox'] 'Журнал работы утилиты. Полный журнал — в файле NtpManager.log.'
    Set-UiTip $script:Ui['BtnStatus']     'w32tm /query /status — состояние синхронизации: текущий источник, время последней удачной синхронизации, смещение, stratum, уровень.'
    Set-UiTip $script:Ui['BtnConfig']     'w32tm /query /configuration — действующие параметры службы (провайдеры, интервалы, пороги коррекции).'
    Set-UiTip $script:Ui['BtnPeers']      'w32tm /query /peers — список источников времени и состояние каждого из них: отвечает ли и когда была удачная синхронизация.'
    Set-UiTip $script:Ui['BtnStrip']      'w32tm /stripchart — 5 замеров подряд у указанного сервера. Значения d: (задержка) и o: (смещение часов) применяются для оценки качества связи с GPS.'
    Set-UiTip $script:Ui['BtnEvents']     'Последние записи службы времени из журнала System: кто/когда синхронизировался, были ли ошибки.'
    Set-UiTip $script:Ui['BtnResync']     'w32tm /resync — заставить службу синхронизироваться немедленно. Требует прав администратора. Если время уже верное, служба может ответить «синхронизация не нужна».'
    Set-UiTip $script:Ui['BtnRediscover'] 'w32tm /resync /rediscover — заново найти источники времени и синхронизироваться сразу. Полезно после смены адреса GPS-сервера.'
    Set-UiTip $script:Ui['BtnPort']       'Показать, какой процесс/служба реально слушает UDP 123. Если это не служба времени, встроенный NTP-сервер не сможет отвечать клиентам.'
    Set-UiTip $script:Ui['BtnFwShow']     'Показать правило брандмауэра для входящего UDP 123, если оно создано (netsh advfirewall firewall show rule).'
    Set-UiTip $script:Ui['BtnFwAdd']      'Разрешить входящий UDP 123 в брандмауэре Windows — без этого клиенты локальной сети не получат время.'
    Set-UiTip $script:Ui['BtnFwDel']      'Удалить созданное утилитой правило брандмауэра. Клиенты локальной сети могут перестать получать время.'
    Set-UiTip $script:Ui['BtnRegister']   'Зарегистрировать службу времени заново (w32tm /register). Нужно, когда службы нет в списке служб: её «снял с регистрации» кто-то командой w32tm /unregister или удалил ключ службы, и тогда её действительно не видно в services.msc. Перед выполнением создаётся резервная копия ветви службы.'
    Set-UiTip $script:Ui['ChkPolicyMode'] 'Если служба времени управляется групповой политикой, её значения важнее реестра службы. С этой галочкой утилита запишет свои параметры и в ветвь политики (HKLM\SOFTWARE\Policies\Microsoft\W32Time) — тогда они подействуют. Если политика задана в gpedit, правильнее настраивать её там, а эту галочку не включать.'
    Set-UiTip $script:Ui['BtnGpedit']     'Открыть редактор локальной групповой политики (gpedit.msc), раздел: Конфигурация компьютера → Административные шаблоны → Система → Служба времени Windows. На сервере без графической оболочки (Server Core) gpedit недоступен — настройте политику с другой машины или удалите ветвь политики.'
    Set-UiTip $script:Ui['BtnPolicyDel']  'Удалить ветвь HKLM\SOFTWARE\Policies\Microsoft\W32Time (с резервной копией в рег-файл). После этого параметры службы будут браться из обычных ключей. Важно: если политика реально включена в gpedit, её значения вернутся при обновлении политики — в этом случае переведите нужные пункты в «Не задано».'
}

function Build-Form {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'NTP Manager ' + $script:Ver + ' — ' + (T 'служба времени, NTP-сервер и NTP-клиент (Windows Server 2008 R2)')
    $form.ClientSize = New-Object System.Drawing.Size(920, 740)
    $form.MinimumSize = New-Object System.Drawing.Size(760, 520)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.KeyPreview = $true
    try { $form.Icon = [System.Drawing.SystemIcons]::Application } catch { }
    $script:Ui['Form'] = $form

    # Подсказки при наведении курсора (заполняются в Set-AllUiTips)
    $tip = New-Object System.Windows.Forms.ToolTip
    $tip.AutoPopDelay = 30000
    $tip.InitialDelay = 400
    $tip.ReshowDelay = 200
    $tip.ShowAlways = $true
    $script:Ui['Tip'] = $tip

    # --- верхняя панель ---
    $top = New-Object System.Windows.Forms.Panel
    $top.Dock = [System.Windows.Forms.DockStyle]::Top
    $top.Height = 52
    [void]$form.Controls.Add($top)

    $b = New-UiButton $top 'Обновить (F5)' 8 6 120 26
    $b.Add_Click({ On-RefreshClick })
    $b = New-UiButton $top 'Проверить NTP' 134 6 130 26
    $b.Add_Click({ On-TestAllClick })
    $b = New-UiButton $top 'Разрешить UDP 123' 270 6 150 26
    $b.Add_Click({ On-FirewallAddClick })
    $b = New-UiButton $top 'Текстовый отчёт' 426 6 140 26
    $b.Add_Click({ On-TextReportClick })
    $b = New-UiButton $top 'Справка' 572 6 90 26
    $b.Add_Click({ On-HelpClick })
    $script:Ui['Summary'] = New-UiLabel $top 'Итог: ещё не проверялось' 8 32 900 18

    # Переключатель языка интерфейса (применяется после перезапуска утилиты)
    [void](New-UiLabel $top 'Язык:' 672 10 40 18)
    $cmbLang = New-Object System.Windows.Forms.ComboBox
    $cmbLang.Location = New-Object System.Drawing.Point(714, 6)
    $cmbLang.Size = New-Object System.Drawing.Size(120, 22)
    $cmbLang.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    [void]$cmbLang.Items.Add('Русский')
    [void]$cmbLang.Items.Add('English')
    $cmbLang.Add_SelectedIndexChanged({ On-LanguageChanged })
    [void]$top.Controls.Add($cmbLang)
    $script:Ui['CmbLang'] = $cmbLang

    # --- нижняя панель: журнал ---
    $bottom = New-Object System.Windows.Forms.Panel
    $bottom.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $bottom.Height = 96
    [void]$form.Controls.Add($bottom)
    $right = New-Object System.Windows.Forms.Panel
    $right.Dock = [System.Windows.Forms.DockStyle]::Right
    $right.Width = 170
    [void]$bottom.Controls.Add($right)
    $b = New-UiButton $right 'Открыть журнал' 4 4 160 26
    $b.Add_Click({ On-OpenLogClick })
    $b = New-UiButton $right 'Открыть папку' 4 34 160 26
    $b.Add_Click({ On-OpenFolderClick })
    $b = New-UiButton $right 'Очистить' 4 64 160 26
    $b.Add_Click({ On-ClearLogClick })
    $logBox = New-Object System.Windows.Forms.RichTextBox
    $logBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $logBox.ReadOnly = $true
    $logBox.Font = (New-MonoFont 8)
    $logBox.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 250)
    $logBox.WordWrap = $false
    [void]$bottom.Controls.Add($logBox)
    $script:Ui['LogBox'] = $logBox

    # --- вкладки ---
    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Location = New-Object System.Drawing.Point(0, 52)
    $tabs.Size = New-Object System.Drawing.Size(920, 592)
    $tabs.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    [void]$form.Controls.Add($tabs)
    $script:Ui['Tabs'] = $tabs

    # ======================= ВКЛАДКА СОСТОЯНИЕ =======================
    $tp1 = New-UiTabPage $tabs 'Состояние'
    $body1 = New-Object System.Windows.Forms.Panel
    $body1.Dock = [System.Windows.Forms.DockStyle]::Fill
    $body1.Padding = New-Object System.Windows.Forms.Padding(8, 8, 8, 8)
    $foot1 = New-Object System.Windows.Forms.Panel
    $foot1.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $foot1.Height = 26
    $lv = New-Object System.Windows.Forms.ListView
    $lv.Dock = [System.Windows.Forms.DockStyle]::Fill
    $lv.View = [System.Windows.Forms.View]::Details
    $lv.FullRowSelect = $true
    $lv.GridLines = $true
    $lv.HideSelection = $false
    $lv.MultiSelect = $false
    [void]$lv.Columns.Add((T 'Параметр'), 250)
    [void]$lv.Columns.Add((T 'Значение'), 400)
    [void]$lv.Columns.Add((T 'Оценка'), 220)
    [void]$body1.Controls.Add($lv)
    $script:Ui['StatusList'] = $lv
    [void](New-UiLabel $foot1 'OK — норма, !! — замечание, XX — ошибка, «--» — справочно. Автообновление «лёгкое» (служба и реестр), полная проверка — по кнопке «Обновить» или раз в 10 минут.' 8 4 880 18)
    [void]$tp1.Controls.Add($body1)
    [void]$tp1.Controls.Add($foot1)

    # ======================= ВКЛАДКА СЛУЖБА =======================
    $tp2 = New-UiTabPage $tabs 'Служба'
    $g1 = New-UiGroup $tp2 'Служба времени Windows (w32time)' 8 8 890 150
    [void](New-UiLabel $g1 'Отображаемое имя:' 12 25 150)
    $script:Ui['SvcName'] = New-UiLabel $g1 '-' 170 25 700
    [void](New-UiLabel $g1 'Состояние:' 12 48 150)
    $script:Ui['SvcState'] = New-UiLabel $g1 '-' 170 48 700
    [void](New-UiLabel $g1 'Тип запуска:' 12 71 150)
    $script:Ui['SvcStart'] = New-UiLabel $g1 '-' 170 71 700
    [void](New-UiLabel $g1 'PID и учётная запись:' 12 94 150)
    $script:Ui['SvcPid'] = New-UiLabel $g1 '-' 170 94 700
    $b = New-UiButton $g1 'Запустить' 12 116 110 26
    $b.Add_Click({ On-ServiceStartClick })
    $b = New-UiButton $g1 'Остановить' 128 116 110 26
    $b.Add_Click({ On-ServiceStopClick })
    $b = New-UiButton $g1 'Перезапустить' 244 116 130 26
    $b.Add_Click({ On-ServiceRestartClick })
    $b = New-UiButton $g1 'Восстановить службу времени' 380 116 230 26
    $b.Add_Click({ On-RegisterServiceClick })
    $script:Ui['BtnRegister'] = $b

    $g2 = New-UiGroup $tp2 'Автозапуск при включении сервера' 8 166 890 80
    $cmb = New-Object System.Windows.Forms.ComboBox
    $cmb.Location = New-Object System.Drawing.Point(12, 28)
    $cmb.Size = New-Object System.Drawing.Size(220, 22)
    $cmb.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    [void]$cmb.Items.Add((T 'Автоматически'))
    [void]$cmb.Items.Add((T 'Вручную'))
    [void]$cmb.Items.Add((T 'Отключена'))
    [void]$g2.Controls.Add($cmb)
    $script:Ui['CmbStartup'] = $cmb
    $b = New-UiButton $g2 'Применить' 244 26 120 26
    $b.Add_Click({ On-StartupModeClick })
    [void](New-UiLabel $g2 'Для сервера времени правильный выбор — «Автоматически».' 376 32 500)

    $g3 = New-UiGroup $tp2 'Мониторинг (пока окно открыто)' 8 254 890 240
    $c = New-UiCheck $g3 'Автообновление состояния каждые' 12 24 250
    $script:Ui['ChkAutoRefresh'] = $c
    $num = New-Object System.Windows.Forms.NumericUpDown
    $num.Location = New-Object System.Drawing.Point(268, 22)
    $num.Size = New-Object System.Drawing.Size(70, 22)
    $num.Minimum = 5
    $num.Maximum = 600
    $num.Value = 15
    [void]$g3.Controls.Add($num)
    $num.Add_ValueChanged({ On-RefreshPeriodChanged })
    $script:Ui['NumRefresh'] = $num
    [void](New-UiLabel $g3 'секунд' 346 24 60)
    $script:Ui['ChkNotify'] = New-UiCheck $g3 'Уведомлять при изменении состояния службы (всплывающее уведомление)' 12 50 700
    $script:Ui['ChkMonitorSntp'] = New-UiCheck $g3 'Проверять отклик NTP-сервера по таймеру (раз в 5 минут)' 12 76 700
    $script:Ui['ChkTray'] = New-UiCheck $g3 'Показывать значок в области уведомлений' 12 102 700
    $script:Ui['ChkTray'].Add_CheckedChanged({ On-TrayCheckChanged })
    $script:Ui['ChkMinToTray'] = New-UiCheck $g3 'При закрытии окна сворачивать в область уведомлений, а не завершать' 12 128 700
    $script:Ui['ChkExpectedServer'] = New-UiCheck $g3 'Считать нормой раздачу времени клиентам (контролировать NTP-сервер)' 12 154 700
    $script:Ui['ChkExpectedClient'] = New-UiCheck $g3 'Считать нормой получение времени от GPS (контролировать NTP-клиент)' 12 180 700
    [void](New-UiLabel $g3 'Внимание: остановка службы времени на контроллере домена может временно нарушить работу Kerberos.' 12 208 860 32)

    $g4 = New-UiGroup $tp2 'Групповая политика службы времени (её значения важнее реестра службы)' 8 502 890 52
    $script:Ui['ChkPolicyMode'] = New-UiCheck $g4 'Записывать параметры и в ветвь политики (SOFTWARE\Policies\Microsoft\W32Time)' 12 20 570
    $b = New-UiButton $g4 'Открыть gpedit' 600 18 130 26
    $b.Add_Click({ On-OpenGpeditClick })
    $script:Ui['BtnGpedit'] = $b
    $b = New-UiButton $g4 'Удалить ветвь политики...' 738 18 140 26
    $b.Add_Click({ On-PolicyRemoveClick })
    $script:Ui['BtnPolicyDel'] = $b

    # ======================= ВКЛАДКА НАСТРОЙКА =======================
    $tp3 = New-UiTabPage $tabs 'Настройка'
    $c1 = New-UiGroup $tp3 'NTP-сервер: эта машина отдаёт время клиентам локальной сети' 8 8 890 100
    $script:Ui['ChkServer'] = New-UiCheck $c1 'Включить провайдер NtpServer (слушать входящие NTP-запросы)' 12 22 800
    $script:Ui['ChkAllowNonstd'] = New-UiCheck $c1 'Разрешить нестандартные комбинации режимов (лучшая совместимость клиентов)' 12 46 800
    $script:Ui['ChkReliable'] = New-UiCheck $c1 'Помечать машину надёжным источником времени (AnnounceFlags = 5)' 12 70 800

    $c2 = New-UiGroup $tp3 'NTP-клиент: получать время от GPS-сервера в локальной сети' 8 116 890 150
    $script:Ui['ChkClient'] = New-UiCheck $c2 'Включить провайдер NtpClient (получать время)' 12 22 500
    [void](New-UiLabel $c2 'Тип источника времени:' 12 50 200)
    $rb1 = New-Object System.Windows.Forms.RadioButton
    $rb1.Text = (T 'Ручной список серверов (NTP) — рекомендуемый вариант')
    $rb1.Location = New-Object System.Drawing.Point(12, 68)
    $rb1.Width = 380
    [void]$c2.Controls.Add($rb1)
    $script:Ui['RadNtp'] = $rb1
    $rb2 = New-Object System.Windows.Forms.RadioButton
    $rb2.Text = (T 'Иерархия домена (NT5DS)')
    $rb2.Location = New-Object System.Drawing.Point(400, 68)
    $rb2.Width = 190
    [void]$c2.Controls.Add($rb2)
    $script:Ui['RadNt5ds'] = $rb2
    $rb3 = New-Object System.Windows.Forms.RadioButton
    $rb3.Text = (T 'Не синхронизировать (NoSync)')
    $rb3.Location = New-Object System.Drawing.Point(596, 68)
    $rb3.Width = 200
    [void]$c2.Controls.Add($rb3)
    $script:Ui['RadNoSync'] = $rb3
    [void](New-UiLabel $c2 'Адрес GPS-сервера времени — можно просто IP (например, 192.168.1.50):' 12 96 560)
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Location = New-Object System.Drawing.Point(12, 116)
    $tb.Size = New-Object System.Drawing.Size(330, 22)
    [void]$c2.Controls.Add($tb)
    $script:Ui['TxtPeers'] = $tb
    $chkFlag = New-UiCheck $c2 'дописывать флаг ,0x9 самому' 352 118 215
    $chkFlag.Checked = $true
    $script:Ui['ChkPeerFlag'] = $chkFlag
    [void](New-UiLabel $c2 'Интервал опроса, с:' 575 96 130)
    $num = New-Object System.Windows.Forms.NumericUpDown
    $num.Location = New-Object System.Drawing.Point(575, 116)
    $num.Size = New-Object System.Drawing.Size(70, 22)
    $num.Minimum = 32
    $num.Maximum = 86400
    $num.Value = 300
    [void]$c2.Controls.Add($num)
    $script:Ui['NumPoll'] = $num

    $c3 = New-UiGroup $tp3 'Прочее (необязательные параметры — оставьте поля пустыми, если не уверены)' 8 272 890 140
    [void](New-UiLabel $c3 'Тип запуска службы:' 12 22 150)
    $cmb2 = New-Object System.Windows.Forms.ComboBox
    $cmb2.Location = New-Object System.Drawing.Point(12, 42)
    $cmb2.Size = New-Object System.Drawing.Size(200, 22)
    $cmb2.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    [void]$cmb2.Items.Add((T 'Автоматически'))
    [void]$cmb2.Items.Add((T 'Вручную'))
    [void]$cmb2.Items.Add((T 'Отключена'))
    [void]$c3.Controls.Add($cmb2)
    $script:Ui['CmbStartupCfg'] = $cmb2
    $script:Ui['ChkFirewall'] = New-UiCheck $c3 'Разрешить входящий UDP 123 в брандмауэре Windows' 230 42 400
    [void](New-UiLabel $c3 'Макс. разовое смещение часов, с:' 12 78 260)
    $tb2 = New-Object System.Windows.Forms.TextBox
    $tb2.Location = New-Object System.Drawing.Point(12, 98)
    $tb2.Size = New-Object System.Drawing.Size(80, 22)
    [void]$c3.Controls.Add($tb2)
    $script:Ui['TxtPhase'] = $tb2
    [void](New-UiLabel $c3 'пусто — не менять; обычно 300, при сильно ушедших часах 3600' 100 102 350 16)
    [void](New-UiLabel $c3 'EventLogFlags:' 480 78 120)
    $tb3 = New-Object System.Windows.Forms.TextBox
    $tb3.Location = New-Object System.Drawing.Point(480, 98)
    $tb3.Size = New-Object System.Drawing.Size(70, 22)
    [void]$c3.Controls.Add($tb3)
    $script:Ui['TxtEvents'] = $tb3
    [void](New-UiLabel $c3 'пусто — не менять; 0..3, подробнее журнал = 2' 558 102 320 16)
    [void](New-UiLabel $c3 'Оба поля необязательны: пустое поле = «оставить как есть». Значения вводятся целыми числами.' 12 118 860 16)

    $c4 = New-UiGroup $tp3 'Что будет изменено (предпросмотр перед применением)' 8 418 890 96
    $rtb = New-Object System.Windows.Forms.RichTextBox
    $rtb.Location = New-Object System.Drawing.Point(12, 20)
    $rtb.Size = New-Object System.Drawing.Size(866, 68)
    $rtb.ReadOnly = $true
    $rtb.Font = (New-MonoFont 9)
    $rtb.BackColor = [System.Drawing.Color]::White
    [void]$c4.Controls.Add($rtb)
    $script:Ui['PrevBox'] = $rtb

    $footHost3 = New-Object System.Windows.Forms.Panel
    $footHost3.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $footHost3.Height = 40
    $b = New-UiButton $footHost3 'Проверить изменения' 8 6 150 28
    $b.Add_Click({ On-PreviewClick })
    $b = New-UiButton $footHost3 'ПРИМЕНИТЬ НАСТРОЙКИ' 166 6 180 28
    $b.Add_Click({ On-ApplyClick })
    $b = New-UiButton $footHost3 'Рекомендуемые значения' 354 6 170 28
    $b.Add_Click({ On-RecommendedClick })
    $b = New-UiButton $footHost3 'Сохранить настройки' 532 6 150 28
    $b.Add_Click({ On-SaveSettingsClick })
    $b = New-UiButton $footHost3 'Импорт из копии...' 690 6 150 28
    $b.Add_Click({ On-ImportBackupClick })
    [void]$tp3.Controls.Add($footHost3)

    # ======================= ВКЛАДКА ДИАГНОСТИКА =======================
    $tp4 = New-UiTabPage $tabs 'Диагностика'
    # Панели-хозяева. Порядок добавления в конце: Fill -> Bottom -> Top:
    # только в этом порядке заливка не наезжает на группы и кнопки.
    $topHost4 = New-Object System.Windows.Forms.Panel
    $topHost4.Dock = [System.Windows.Forms.DockStyle]::Top
    $topHost4.Height = 256
    $boxHost4 = New-Object System.Windows.Forms.Panel
    $boxHost4.Dock = [System.Windows.Forms.DockStyle]::Fill
    $boxHost4.Padding = New-Object System.Windows.Forms.Padding(8, 8, 8, 8)
    $footHost4 = New-Object System.Windows.Forms.Panel
    $footHost4.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $footHost4.Height = 40
    $d1 = New-UiGroup $topHost4 'Проверка сервера времени SNTP-запросом (без прав администратора)' 8 8 890 106
    [void](New-UiLabel $d1 'Адрес сервера (IP или имя):' 12 22 200)
    $tb4 = New-Object System.Windows.Forms.TextBox
    $tb4.Location = New-Object System.Drawing.Point(12, 42)
    $tb4.Size = New-Object System.Drawing.Size(240, 22)
    [void]$d1.Controls.Add($tb4)
    $script:Ui['TxtCheckServer'] = $tb4
    $b = New-UiButton $d1 'Проверить этот сервер' 262 40 160 26
    $b.Add_Click({ On-TestPeerClick })
    $b = New-UiButton $d1 'Проверить 127.0.0.1' 430 40 150 26
    $b.Add_Click({ On-TestLocalClick })
    $b = New-UiButton $d1 'Стабильность: 5 замеров' 588 40 170 26
    $b.Add_Click({ On-TestStabilityClick })
    [void](New-UiLabel $d1 'Подсказка: чтобы проверить доступность сервера для клиентов, запустите такую же проверку с клиентской машины.' 12 74 860 24)

    $d2 = New-UiGroup $topHost4 'Команды службы времени: верхний ряд только читает, нижние меняют состояние (нужны права администратора)' 8 122 890 134
    $b = New-UiButton $d2 'Состояние синхронизации' 12 20 170 26
    $b.Add_Click({ On-CmdStatusClick })
    $script:Ui['BtnStatus'] = $b
    $b = New-UiButton $d2 'Действующие настройки' 188 20 170 26
    $b.Add_Click({ On-CmdConfigClick })
    $script:Ui['BtnConfig'] = $b
    $b = New-UiButton $d2 'Источники времени' 364 20 150 26
    $b.Add_Click({ On-CmdPeersClick })
    $script:Ui['BtnPeers'] = $b
    $b = New-UiButton $d2 'Замеры с сервера (5)' 520 20 150 26
    $b.Add_Click({ On-CmdStripClick })
    $script:Ui['BtnStrip'] = $b
    $b = New-UiButton $d2 'События службы' 676 20 180 26
    $b.Add_Click({ On-CmdEventsClick })
    $script:Ui['BtnEvents'] = $b
    $b = New-UiButton $d2 'Синхронизировать сейчас' 12 50 170 26
    $b.Add_Click({ On-CmdResyncClick })
    $script:Ui['BtnResync'] = $b
    $b = New-UiButton $d2 'Перечитать источники' 188 50 170 26
    $b.Add_Click({ On-CmdRediscoverClick })
    $script:Ui['BtnRediscover'] = $b
    $b = New-UiButton $d2 'Кто слушает порт 123' 364 50 160 26
    $b.Add_Click({ On-CmdPortClick })
    $script:Ui['BtnPort'] = $b
    $b = New-UiButton $d2 'Правило брандмауэра: показать' 12 80 200 26
    $b.Add_Click({ On-FirewallShowClick })
    $script:Ui['BtnFwShow'] = $b
    $b = New-UiButton $d2 'Разрешить UDP 123' 218 80 160 26
    $b.Add_Click({ On-FirewallAddClick })
    $script:Ui['BtnFwAdd'] = $b
    $b = New-UiButton $d2 'Удалить правило' 384 80 160 26
    $b.Add_Click({ On-FirewallRemoveClick })
    $script:Ui['BtnFwDel'] = $b
    [void](New-UiLabel $d2 'Это обёртки над w32tm: состояние = /query /status, настройки = /query /configuration, источники = /query /peers, замеры = /stripchart, синхронизировать = /resync.' 12 110 860 18)

    $rtb2 = New-Object System.Windows.Forms.RichTextBox
    $rtb2.Dock = [System.Windows.Forms.DockStyle]::Fill
    $rtb2.ReadOnly = $true
    $rtb2.Font = (New-MonoFont 9)
    $rtb2.WordWrap = $false
    $rtb2.ScrollBars = [System.Windows.Forms.RichTextBoxScrollBars]::Both
    [void]$boxHost4.Controls.Add($rtb2)
    $script:Ui['OutBox'] = $rtb2
    $b = New-UiButton $footHost4 'Очистить' 8 6 100 26
    $b.Add_Click({ On-ClearOutputClick })
    $b = New-UiButton $footHost4 'Сохранить в файл' 114 6 150 26
    $b.Add_Click({ On-SaveOutputClick })
    $b = New-UiButton $footHost4 'Копировать' 270 6 110 26
    $b.Add_Click({ On-CopyOutputClick })
    $b = New-UiButton $footHost4 'Текстовый отчёт' 386 6 150 26
    $b.Add_Click({ On-TextReportClick })
    [void]$tp4.Controls.Add($boxHost4)
    [void]$tp4.Controls.Add($footHost4)
    [void]$tp4.Controls.Add($topHost4)

    # --- таймер ---
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 15000
    $timer.Add_Tick({ On-TimerTick })
    $script:Ui['Timer'] = $timer

    # --- значок в области уведомлений ---
    try {
        $ni = New-Object System.Windows.Forms.NotifyIcon
        $ni.Icon = [System.Drawing.SystemIcons]::Application
        $ni.Text = 'NTP Manager'
        $menu = New-Object System.Windows.Forms.ContextMenu
        $mi1 = New-Object System.Windows.Forms.MenuItem((T 'Показать окно'))
        $mi1.Add_Click({ On-TrayShowClick })
        $mi2 = New-Object System.Windows.Forms.MenuItem((T 'Проверить состояние'))
        $mi2.Add_Click({ On-RefreshClick })
        $mi3 = New-Object System.Windows.Forms.MenuItem((T 'Выход'))
        $mi3.Add_Click({ On-TrayExitClick })
        [void]$menu.MenuItems.Add($mi1)
        [void]$menu.MenuItems.Add($mi2)
        [void]$menu.MenuItems.Add($mi3)
        $ni.ContextMenu = $menu
        $ni.Add_DoubleClick({ On-TrayShowClick })
        $ni.Visible = $false
        $script:Ui['Tray'] = $ni
    } catch {
        $script:Ui['Tray'] = $null
        Add-Log ('Не удалось создать значок в области уведомлений: ' + $_.Exception.Message) 'WARN'
    }

    $form.Add_Resize({ On-FormResize })
    $form.Add_KeyDown({ On-FormKeyDown })
    $form.Add_FormClosing({ On-FormClosing })
    Set-AllUiTips
    return $form
}

# ---------------------------------------------------------------------------
# Обновление окна
# ---------------------------------------------------------------------------
function Get-UiBool {
    param([string]$Key)
    if (-not $script:Ui.ContainsKey($Key)) { return $false }
    $c = $script:Ui[$Key]
    if ($c -eq $null) { return $false }
    return [bool]$c.Checked
}

function Update-TrayText {
    $tray = $script:Ui['Tray']
    if ($tray -eq $null) { return }
    try {
        $snap = Get-ServiceSnapshot -Fast
        $text = 'NTP: служба ' + $snap.StatusRu
        if ($text.Length -gt 60) { $text = $text.Substring(0, 60) }
        $tray.Text = (TPart $text)
    } catch { }
}

function Show-TrayBalloon {
    param([string]$Title, [string]$Text)
    $tray = $script:Ui['Tray']
    if ($tray -eq $null) { return }
    if (-not (Get-UiBool 'ChkTray')) { return }
    try {
        $tray.Visible = $true
        $tray.ShowBalloonTip(8000, $Title, $Text, [System.Windows.Forms.ToolTipIcon]::Warning)
    } catch { }
}

function Refresh-StatusView {
    param([switch]$Quiet, [switch]$Full)
    $lv = $script:Ui['StatusList']
    if ($lv -eq $null) { return }
    if (-not $Quiet) { [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::WaitCursor }
    try {
        $rows = Get-StatusRows -ExpectedServer (Get-UiBool 'ChkExpectedServer') -ExpectedClient (Get-UiBool 'ChkExpectedClient') -Fast:(-not $Full)
        $lv.BeginUpdate()
        $lv.Items.Clear()
        foreach ($r in $rows) {
            $it = New-Object System.Windows.Forms.ListViewItem($r.Item)
            [void]$it.SubItems.Add($r.Value)
            [void]$it.SubItems.Add($r.Verdict)
            if ($r.Level -eq 'ok') { $it.ForeColor = [System.Drawing.Color]::FromArgb(0, 110, 0) }
            elseif ($r.Level -eq 'warn') { $it.ForeColor = [System.Drawing.Color]::FromArgb(190, 110, 0) }
            elseif ($r.Level -eq 'err') { $it.ForeColor = [System.Drawing.Color]::FromArgb(190, 0, 0) }
            else { $it.ForeColor = [System.Drawing.Color]::FromArgb(80, 80, 80) }
            [void]$lv.Items.Add($it)
        }
        $lv.EndUpdate()
        $sum = Get-StatusSummary $rows
        $color = [System.Drawing.Color]::FromArgb(0, 110, 0)
        if ($sum.Level -eq 'warn') { $color = [System.Drawing.Color]::FromArgb(190, 110, 0) }
        if ($sum.Level -eq 'err') { $color = [System.Drawing.Color]::FromArgb(190, 0, 0) }
        $tail = '  •  обновлено ' + (Get-Date).ToString('HH:mm:ss')
        if (-not $script:IsAdmin) { $tail = $tail + '  •  БЕЗ ПРАВ АДМИНИСТРАТОРА: только просмотр' }
        $summaryText = 'ИТОГ: ' + $sum.Text + ' (ок ' + $sum.Ok + ', замечаний ' + $sum.Warnings + ', ошибок ' + $sum.Errors + ')' + $tail
        $script:Ui['Summary'].Text = (TPart $summaryText)
        $script:Ui['Summary'].ForeColor = $color
        $script:LastSummary = $sum

        $snap = Get-ServiceSnapshot -Fast
        $stateNow = [string]$snap.Status
        if ($script:LastState -ne '' -and $stateNow -ne $script:LastState -and (Get-UiBool 'ChkNotify')) {
            Add-Log ('Состояние службы изменилось: ' + $script:LastState + ' -> ' + $stateNow) 'WARN'
            Show-TrayBalloon 'NTP Manager' ('Служба времени: ' + (Convert-ServiceStateRu $stateNow))
        }
        $script:LastState = $stateNow
        Update-TrayText
    } finally {
        if (-not $Quiet) { [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default }
    }
}

function Refresh-ServiceView {
    param([switch]$Fast)
    $snap = Get-ServiceSnapshot -Fast:$Fast
    if ($script:Ui['SvcName'] -ne $null) { $script:Ui['SvcName'].Text = $snap.DisplayName }
    if ($script:Ui['SvcState'] -ne $null) {
        $script:Ui['SvcState'].Text = $snap.StatusRu
        if ($snap.Status -eq 'Running') { $script:Ui['SvcState'].ForeColor = [System.Drawing.Color]::FromArgb(0, 110, 0) }
        elseif ($snap.Status -eq 'Stopped') { $script:Ui['SvcState'].ForeColor = [System.Drawing.Color]::FromArgb(190, 0, 0) }
        else { $script:Ui['SvcState'].ForeColor = [System.Drawing.Color]::FromArgb(190, 110, 0) }
    }
    if ($script:Ui['SvcStart'] -ne $null) { $script:Ui['SvcStart'].Text = $snap.StartModeRu }
    if ($script:Ui['SvcPid'] -ne $null) {
        if ($snap.ProcessId -gt 0) {
            $txt = 'PID ' + $snap.ProcessId
            if ($snap.StartName -ne '') { $txt = $txt + ', учётная запись ' + $snap.StartName }
            $script:Ui['SvcPid'].Text = $txt
        }
    }
    if ($script:Ui['CmbStartup'] -ne $null) {
        if ($snap.StartMode -eq 'Auto') { $script:Ui['CmbStartup'].SelectedIndex = 0 }
        elseif ($snap.StartMode -eq 'Manual') { $script:Ui['CmbStartup'].SelectedIndex = 1 }
        elseif ($snap.StartMode -eq 'Disabled') { $script:Ui['CmbStartup'].SelectedIndex = 2 }
    }
}

function Load-SettingsIntoUi {
    $script:LangUiLoading = $true
    $s = Get-Settings
    if ($script:Ui['CmbLang'] -ne $null) {
        if ($script:Lang -eq 'en') { $script:Ui['CmbLang'].SelectedIndex = 1 } else { $script:Ui['CmbLang'].SelectedIndex = 0 }
    }
    if ($script:Ui['TxtPeers'] -ne $null) { $script:Ui['TxtPeers'].Text = [string]$s['ServerList'] }
    $p = Parse-IntOrNull ([string]$s['PollInterval'])
    if ($p -ne $null -and $p -ge 32 -and $p -le 86400) { $script:Ui['NumPoll'].Value = $p }
    $t = [string]$s['Type']
    if ($t -eq 'NT5DS') { $script:Ui['RadNt5ds'].Checked = $true }
    elseif ($t -eq 'NoSync') { $script:Ui['RadNoSync'].Checked = $true }
    else { $script:Ui['RadNtp'].Checked = $true }
    $script:Ui['ChkServer'].Checked = ($s['EnableServer'] -eq '1')
    $script:Ui['ChkAllowNonstd'].Checked = ($s['AllowNonstandard'] -eq '1')
    $script:Ui['ChkClient'].Checked = ($s['EnableClient'] -eq '1')
    $script:Ui['ChkReliable'].Checked = ($s['Reliable'] -eq '1')
    $script:Ui['ChkFirewall'].Checked = ($s['AddFirewall'] -eq '1')
    $script:Ui['TxtPhase'].Text = [string]$s['MaxAllowedPhaseOffset']
    $script:Ui['TxtEvents'].Text = [string]$s['EventLogFlags']
    $sm = [string]$s['StartupMode']
    if ($sm -eq 'Manual') { $script:Ui['CmbStartupCfg'].SelectedIndex = 1 }
    elseif ($sm -eq 'Disabled') { $script:Ui['CmbStartupCfg'].SelectedIndex = 2 }
    else { $script:Ui['CmbStartupCfg'].SelectedIndex = 0 }
    $ar = Parse-IntOrNull ([string]$s['AutoRefreshSec'])
    if ($ar -ne $null -and $ar -ge 5 -and $ar -le 600) { $script:Ui['NumRefresh'].Value = $ar }
    $script:Ui['ChkAutoRefresh'].Checked = $true
    $script:Ui['ChkMonitorSntp'].Checked = ($s['MonitorSntp'] -eq '1')
    $script:Ui['ChkNotify'].Checked = ($s['NotifyOnChange'] -eq '1')
    $script:Ui['ChkMinToTray'].Checked = ($s['MinimizeToTray'] -eq '1')
    $script:Ui['ChkPeerFlag'].Checked = ($s['PeerFlag'] -ne '0')
    $script:Ui['ChkPolicyMode'].Checked = ($s['PolicyMode'] -eq '1')
    $script:Ui['ChkExpectedServer'].Checked = ($s['ExpectedServer'] -eq '1')
    $script:Ui['ChkExpectedClient'].Checked = ($s['ExpectedClient'] -eq '1')
    $trayWanted = ($s['MinimizeToTray'] -eq '1')
    $script:Ui['ChkTray'].Checked = $trayWanted
    if ($script:Ui['Tray'] -ne $null) { $script:Ui['Tray'].Visible = $trayWanted }
    $cs = [string]$s['CheckServer']
    if ($cs -ne '') {
        $script:Ui['TxtCheckServer'].Text = $cs
    } else {
        $peerList = @(Get-PeerHostsOnly ([string]$s['ServerList']))
        if ($peerList.Count -gt 0) { $script:Ui['TxtCheckServer'].Text = $peerList[0] }
    }
    if ($script:Ui['Timer'] -ne $null) { $script:Ui['Timer'].Interval = [int]($script:Ui['NumRefresh'].Value * 1000) }
    $script:LangUiLoading = $false
}

function Save-SettingsFromUi {
    $s = Get-Settings
    $s['ServerList']   = [string]$script:Ui['TxtPeers'].Text.Trim()
    $s['PollInterval'] = [string][int]$script:Ui['NumPoll'].Value
    if ($script:Ui['RadNtp'].Checked) { $s['Type'] = 'NTP' }
    elseif ($script:Ui['RadNt5ds'].Checked) { $s['Type'] = 'NT5DS' }
    else { $s['Type'] = 'NoSync' }
    if (Get-UiBool 'ChkServer') { $s['EnableServer'] = '1' } else { $s['EnableServer'] = '0' }
    if (Get-UiBool 'ChkAllowNonstd') { $s['AllowNonstandard'] = '1' } else { $s['AllowNonstandard'] = '0' }
    if (Get-UiBool 'ChkClient') { $s['EnableClient'] = '1' } else { $s['EnableClient'] = '0' }
    if (Get-UiBool 'ChkReliable') { $s['Reliable'] = '1' } else { $s['Reliable'] = '0' }
    if (Get-UiBool 'ChkFirewall') { $s['AddFirewall'] = '1' } else { $s['AddFirewall'] = '0' }
    $s['MaxAllowedPhaseOffset'] = [string]$script:Ui['TxtPhase'].Text.Trim()
    $s['EventLogFlags'] = [string]$script:Ui['TxtEvents'].Text.Trim()
    if ($script:Ui['CmbStartupCfg'].SelectedIndex -eq 1) { $s['StartupMode'] = 'Manual' }
    elseif ($script:Ui['CmbStartupCfg'].SelectedIndex -eq 2) { $s['StartupMode'] = 'Disabled' }
    else { $s['StartupMode'] = 'Automatic' }
    $s['AutoRefreshSec'] = [string][int]$script:Ui['NumRefresh'].Value
    if (Get-UiBool 'ChkMonitorSntp') { $s['MonitorSntp'] = '1' } else { $s['MonitorSntp'] = '0' }
    if (Get-UiBool 'ChkNotify') { $s['NotifyOnChange'] = '1' } else { $s['NotifyOnChange'] = '0' }
    if (Get-UiBool 'ChkExpectedServer') { $s['ExpectedServer'] = '1' } else { $s['ExpectedServer'] = '0' }
    if (Get-UiBool 'ChkExpectedClient') { $s['ExpectedClient'] = '1' } else { $s['ExpectedClient'] = '0' }
    if (Get-UiBool 'ChkMinToTray') { $s['MinimizeToTray'] = '1' } else { $s['MinimizeToTray'] = '0' }
    if (Get-UiBool 'ChkPeerFlag') { $s['PeerFlag'] = '1' } else { $s['PeerFlag'] = '0' }
    if (Get-UiBool 'ChkPolicyMode') { $s['PolicyMode'] = '1' } else { $s['PolicyMode'] = '0' }
    if ($script:Ui['CmbLang'] -ne $null) {
        if ($script:Ui['CmbLang'].SelectedIndex -eq 1) { $s['Language'] = 'en' } else { $s['Language'] = 'ru' }
    }
    $s['CheckServer'] = [string]$script:Ui['TxtCheckServer'].Text.Trim()
    return (Save-Settings -Settings $s)
}

function Collect-OptionsFromUi {
    $o = @{}
    if (Get-UiBool 'ChkServer') { $o['ServerEnabled'] = 1 } else { $o['ServerEnabled'] = 0 }
    if (Get-UiBool 'ChkAllowNonstd') { $o['AllowNonstandard'] = 1 } else { $o['AllowNonstandard'] = 0 }
    if (Get-UiBool 'ChkReliable') { $o['Reliable'] = $true } else { $o['Reliable'] = $false }
    if (Get-UiBool 'ChkClient') { $o['ClientEnabled'] = 1 } else { $o['ClientEnabled'] = 0 }
    if ($script:Ui['RadNt5ds'].Checked) { $o['Type'] = 'NT5DS' }
    elseif ($script:Ui['RadNoSync'].Checked) { $o['Type'] = 'NoSync' }
    else { $o['Type'] = 'NTP' }
    $peers = Get-PeerListNormalized ([string]$script:Ui['TxtPeers'].Text)
    if ($peers -ne '' -and (Get-UiBool 'ChkPeerFlag')) { $peers = Add-DefaultPeerFlags $peers }
    if ($peers -ne '') { $o['Peers'] = $peers }
    $o['PollInterval'] = [int]$script:Ui['NumPoll'].Value
    if ($script:Ui['CmbStartupCfg'].SelectedIndex -eq 1) { $o['StartupMode'] = 'Manual' }
    elseif ($script:Ui['CmbStartupCfg'].SelectedIndex -eq 2) { $o['StartupMode'] = 'Disabled' }
    else { $o['StartupMode'] = 'Automatic' }
    if (Get-UiBool 'ChkFirewall') { $o['AddFirewall'] = $true }
    if (Get-UiBool 'ChkPolicyMode') { $o['UsePolicyBranch'] = $true }
    $phase = Parse-IntOrNull ([string]$script:Ui['TxtPhase'].Text)
    if ($phase -ne $null -and $phase -ge 0) { $o['MaxAllowedPhaseOffset'] = $phase }
    $ev = Parse-IntOrNull ([string]$script:Ui['TxtEvents'].Text)
    if ($ev -ne $null -and $ev -ge 0 -and $ev -le 3) { $o['EventLogFlags'] = $ev }
    return $o
}

function Get-PeerFlagWarning {
    param([hashtable]$Options)
    if (-not (Get-UiBool 'ChkClient')) { return '' }
    if (-not $Options.ContainsKey('Peers')) { return '' }
    $noFlag = New-Object System.Collections.ArrayList
    foreach ($p in ([string]$Options['Peers']).Split(' ')) {
        if ($p -ne '' -and $p.IndexOf(',') -lt 0) { [void]$noFlag.Add($p) }
    }
    if ($noFlag.Count -eq 0) { return '' }
    return ('ВНИМАНИЕ: у адреса ' + ($noFlag -join ', ') + ' не указан флаг — служба будет опрашивать источник по своему расписанию (64–1024 с), а не по заданному интервалу опроса. Включите галочку «дописывать флаг ,0x9 самому».')
}

# Предупреждение о том, что параметры службы времени заданы групповой политикой.
function Get-PolicyWarning {
    $pol = Get-W32TimePolicyState
    if (-not $pol.Exists -or $pol.Items.Count -eq 0) { return '' }
    return ('ВНИМАНИЕ: параметры службы времени заданы групповой политикой и перекрывают реестр: ' + $pol.Summary + '.' + [Environment]::NewLine + 'Изменения утилиты будут действовать только после отмены политики: gpedit.msc → Административные шаблоны → Система → Служба времени Windows → перевести нужные пункты в «Не задано» (или удалить ветвь реестра HKLM\SOFTWARE\Policies\Microsoft\W32Time).')
}

function Format-SntpResult {
    param($Q, [string]$Title)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('--- ' + $Title + ' ---')
    if ($Q -eq $null) { [void]$sb.AppendLine('проверка не выполнялась'); return $sb.ToString() }
    if (-not $Q.Success) {
        [void]$sb.AppendLine('НЕТ ОТВЕТА от ' + $Q.Server + ':' + $Q.Port)
        [void]$sb.AppendLine('  ' + $Q.Error)
        [void]$sb.AppendLine('  Что проверить: доступность узла (ping), запущена ли служба времени на нём,')
        [void]$sb.AppendLine('  открыт ли входящий UDP 123 в брандмауэре сервера.')
        return $sb.ToString()
    }
    [void]$sb.AppendLine('Сервер            : ' + $Q.Server + ' (' + $Q.ServerIp + ':' + $Q.Port + ')')
    [void]$sb.AppendLine('Версия/режим ответа: NTP v' + $Q.Version + ', режим ' + $Q.Mode)
    [void]$sb.AppendLine('Stratum           : ' + $Q.Stratum + '  (1 — первичный источник, например GPS)')
    [void]$sb.AppendLine('Идентификатор источника: ' + $Q.RefId)
    if ($Q.ServerUtc -ne $null) {
        [void]$sb.AppendLine('Время сервера UTC : ' + $Q.ServerUtc.ToString('yyyy-MM-dd HH:mm:ss.fff'))
    } else {
        [void]$sb.AppendLine('Время сервера UTC : сервер не вернул метку передачи')
    }
    [void]$sb.AppendLine('Смещение          : ' + [Math]::Round($Q.OffsetMs, 1) + ' мс (положительное = наши часы спешат) [' + $Q.OffsetMeaning + ']')
    [void]$sb.AppendLine('Задержка обмена   : ' + [Math]::Round($Q.DelayMs, 1) + ' мс')
    [void]$sb.AppendLine('Root delay/disp   : ' + [Math]::Round($Q.RootDelayMs, 1) + ' / ' + [Math]::Round($Q.RootDispMs, 1) + ' мс')
    if ($Q.Unsynchronized) {
        [void]$sb.AppendLine('ВНИМАНИЕ: сервер отвечает, но помечает себя несинхронизированным (LI=' + $Q.Leap + ', stratum=' + $Q.Stratum + ').')
        [void]$sb.AppendLine('  Клиенты обычно игнорируют такое время — проверьте на сервере источник GPS.')
    } else {
        [void]$sb.AppendLine('Состояние         : сервер синхронизирован')
    }
    return $sb.ToString()
}

function Format-StabilityResult {
    param($S)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('--- Стабильность ответов ' + $S.Server + ' (' + $S.Samples + ' запросов) ---')
    [void]$sb.AppendLine('Получено ответов: ' + $S.Received + ' из ' + $S.Samples + ', потеряно: ' + $S.Lost)
    if ($S.Received -gt 0) {
        [void]$sb.AppendLine('Смещение: мин ' + [Math]::Round($S.MinOffsetMs, 1) + ' мс, среднее ' + [Math]::Round($S.AvgOffsetMs, 1) + ' мс, макс ' + [Math]::Round($S.MaxOffsetMs, 1) + ' мс')
        [void]$sb.AppendLine('Средняя задержка обмена: ' + [Math]::Round($S.AvgDelayMs, 1) + ' мс, stratum ' + $S.Stratum)
        [void]$sb.AppendLine('Разброс смещения: ' + [Math]::Round(($S.MaxOffsetMs - $S.MinOffsetMs), 1) + ' мс')
    }
    if ($S.Lost -gt 0) { [void]$sb.AppendLine('ВНИМАНИЕ: часть запросов потеряна — возможны потери в сети или блокировка UDP 123.') }
    return $sb.ToString()
}

# ---------------------------------------------------------------------------
# Обработчики кнопок (в событийных обработчиках доступны только $script: и функции)
# ---------------------------------------------------------------------------
function On-RefreshClick {
    Refresh-StatusView -Full
    Refresh-ServiceView
}

function On-TestAllClick {
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('=== Проверка серверов времени ===')
    $q1 = Invoke-NtpCheck -Server '127.0.0.1' -Samples 1 -TimeoutMs 2500
    $script:SntpLocal = $q1
    [void]$lines.Add($q1.Text)
    $st = Get-NtpConfigState
    $peers = @(Get-PeerHostsOnly ([string]$st.Peers))
    if ($peers.Count -eq 0) {
        [void]$lines.Add('Серверы времени в настройках не указаны — внешний источник не проверялся.')
    } else {
        foreach ($peer in $peers) {
            $q = Invoke-NtpCheck -Server $peer -Samples 1 -TimeoutMs 2500
            [void]$lines.Add($q.Text)
            if ($script:SntpPeerServer -eq '' -or $script:SntpPeerServer -eq $peer) {
                $script:SntpPeer = $q
                $script:SntpPeerServer = $peer
            }
        }
    }
    Set-OutputText ($lines -join [Environment]::NewLine)
    Refresh-StatusView
    Refresh-ServiceView
}

function On-TestLocalClick {
    Set-OutputText ((Invoke-NtpCheck -Server '127.0.0.1' -Samples 1 -TimeoutMs 2500).Text)
}

function On-TestPeerClick {
    $srv = [string]$script:Ui['TxtCheckServer'].Text.Trim()
    if ($srv -eq '') { Show-Error 'Укажите адрес сервера для проверки.'; return }
    $q = Invoke-NtpCheck -Server $srv -Samples 1 -TimeoutMs 3000
    Set-OutputText $q.Text
    $script:SntpPeer = $q
    $script:SntpPeerServer = $srv
    Refresh-StatusView
}

function On-TestStabilityClick {
    $srv = [string]$script:Ui['TxtCheckServer'].Text.Trim()
    if ($srv -eq '') { $srv = '127.0.0.1' }
    [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        $s = Invoke-NtpCheck -Server $srv -Samples 5 -PauseMs 800 -TimeoutMs 2500
    } finally {
        [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default
    }
    Set-OutputText $s.Text
}

function On-ServiceStartClick {
    if (-not $script:IsAdmin) { Show-Error 'Нужны права администратора. Перезапустите утилиту от имени администратора.'; return }
    [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::WaitCursor
    try { $e = Start-TimeService -TimeoutSec 40 } finally { [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default }
    if ($e -ne '') { Add-Log ('Запуск службы: ' + $e) 'ERROR' } else { Add-Log 'Служба времени запущена.' }
    Refresh-ServiceView
    Refresh-StatusView
}

function On-ServiceStopClick {
    if (-not $script:IsAdmin) { Show-Error 'Нужны права администратора.'; return }
    if (-not (Ask-Confirm 'Остановить службу времени Windows? Клиенты локальной сети перестанут получать время, а эта машина — синхронизироваться с GPS.')) { return }
    [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::WaitCursor
    try { $e = Stop-TimeService -TimeoutSec 40 } finally { [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default }
    if ($e -ne '') { Add-Log ('Остановка службы: ' + $e) 'ERROR' } else { Add-Log 'Служба времени остановлена.' }
    Refresh-ServiceView
    Refresh-StatusView
}

function On-ServiceRestartClick {
    if (-not $script:IsAdmin) { Show-Error 'Нужны права администратора.'; return }
    if (-not (Ask-Confirm 'Перезапустить службу времени Windows? Это короткий разрыв синхронизации.')) { return }
    [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::WaitCursor
    try { $e = Restart-TimeService -TimeoutSec 40 } finally { [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default }
    if ($e -ne '') { Add-Log ('Перезапуск службы: ' + $e) 'ERROR' } else { Add-Log 'Служба времени перезапущена.' }
    Refresh-ServiceView
    Refresh-StatusView
}

function On-StartupModeClick {
    if (-not $script:IsAdmin) { Show-Error 'Нужны права администратора.'; return }
    $idx = $script:Ui['CmbStartup'].SelectedIndex
    $mode = 'Automatic'
    if ($idx -eq 1) { $mode = 'Manual' }
    if ($idx -eq 2) { $mode = 'Disabled' }
    $e = Set-TimeServiceStartupMode $mode
    if ($e -ne '') { Show-Error $e; Add-Log ('Тип запуска: ' + $e) 'ERROR' }
    else { Add-Log ('Тип запуска службы: ' + (Convert-StartModeRu $mode)) }
    Refresh-ServiceView
    Refresh-StatusView
}

function On-RegisterServiceClick {
    if (-not $script:IsAdmin) { Show-Error 'Нужны права администратора. Перезапустите утилиту от имени администратора.'; return }
    $snap = Get-ServiceSnapshot
    $nl = [Environment]::NewLine
    $txt = 'Восстановить (зарегистрировать заново) службу времени Windows?' + $nl + $nl
    if (-not $snap.Exists) {
        $txt = $txt + 'Служба СЕЙЧАС НЕ ЗАРЕГИСТРИРОВАНА — именно поэтому её не видно в списке служб.' + $nl + $nl
    }
    $txt = $txt + 'Будет выполнено: w32tm /register, тип запуска «Автоматически», запуск службы.' + $nl
    $txt = $txt + 'Перед этим создаётся резервная копия ветви службы в рег-файл. После регистрации проверьте настройки на вкладке «Настройка» и при необходимости примените их.' + $nl + $nl + 'Продолжить?'
    if (-not (Ask-Confirm $txt 'Восстановление службы времени')) { return }
    [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::WaitCursor
    $log = $null
    try { $log = Register-TimeService } finally { [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default }
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('=== Восстановление службы времени (w32tm /register) ===')
    foreach ($l in $log) { [void]$lines.Add('  ' + $l) }
    Set-OutputText ($lines -join $nl)
    Refresh-ServiceView
    Refresh-StatusView -Full
    $snap2 = Get-ServiceSnapshot
    if ($snap2.Exists) {
        Show-Info ('Служба времени зарегистрирована: ' + $snap2.StatusRu + '.' + $nl + 'Теперь на вкладке «Настройка» задайте раздачу времени и адрес GPS-сервера.')
    } else {
        Show-Error ('Служба всё ещё не видна в списке служб.' + $nl + 'Проверьте файл %windir%\system32\w32time.dll (восстановить: sfc /scannow) и посмотрите журнал утилиты.') 
    }
}

function On-OpenGpeditClick {
    $gpedit = [System.IO.Path]::Combine($env:SystemRoot, 'System32\gpedit.msc')
    if (-not [System.IO.File]::Exists($gpedit)) {
        Show-Info ('Файл gpedit.msc не найден (на Server Core редактор политик недоступен).' + [Environment]::NewLine + [Environment]::NewLine + 'Настроить политику можно с другой машины или удалить ветвь политики кнопкой «Удалить ветвь политики...».')
        return
    }
    try {
        Start-Process -FilePath 'mmc.exe' -ArgumentList $gpedit
        Add-Log 'Открыт редактор локальной групповой политики.'
    } catch {
        Show-Error ('Не удалось открыть gpedit.msc: ' + $_.Exception.Message)
    }
}

function On-PolicyRemoveClick {
    if (-not $script:IsAdmin) { Show-Error 'Нужны права администратора.'; return }
    $pol = Get-W32TimePolicyState
    $nl = [Environment]::NewLine
    if (-not $pol.Exists -or $pol.Items.Count -eq 0) { Show-Info 'Ветвь политики службы времени не найдена — удалять нечего.'; return }
    $txt = 'Удалить ветвь групповой политики службы времени?' + $nl + $nl + 'Сейчас там заданы:' + $nl + ($pol.Items -join $nl) + $nl + $nl
    $txt = $txt + 'Перед удалением ветвь будет сохранена в рег-файл (папка NtpManager-backup).' + $nl
    $txt = $txt + 'Важно: если эти значения включает групповая политика (gpedit), они вернутся при следующем обновлении политики — тогда переведите нужные пункты в «Не задано».' + $nl + $nl + 'Продолжить?'
    if (-not (Ask-Confirm $txt 'Удаление ветви политики')) { return }
    $e = Remove-W32TimePolicyBranch
    if ($e -ne '') { Show-Error ('Не удалось удалить ветвь политики: ' + $e); return }
    Refresh-StatusView -Full
    Show-Info ('Ветвь политики удалена. Параметры службы снова берутся из обычных ключей.' + $nl + 'Если после обновления политики они вернутся — настраивайте через gpedit.')
}

function On-LanguageChanged {
    if ($script:LangUiLoading) { return }
    $want = 'ru'
    if ($script:Ui['CmbLang'].SelectedIndex -eq 1) { $want = 'en' }
    if ($want -eq $script:Lang) { return }
    $s = Get-Settings
    $s['Language'] = $want
    [void](Save-Settings -Settings $s)
    $script:Lang = $want
    $nl = [Environment]::NewLine
    if ($want -eq 'en') {
        $msg = 'The interface language has been saved: English.' + $nl + $nl + 'Restart the utility now to apply it?'
    } else {
        $msg = 'Язык интерфейса сохранён: русский.' + $nl + $nl + 'Перезапустить утилиту сейчас, чтобы применить?'
    }
    if (Ask-Confirm $msg 'NTP Manager') { Restart-UtilityInstance }
}

# Перезапуск утилиты с теми же правами (нужен после смены языка).
function Restart-UtilityInstance {
    if ($script:ScriptFull -eq '') {
        Show-Info 'Перезапустите утилиту вручную, чтобы применить язык.'
        return
    }
    $psExe = [System.IO.Path]::Combine($env:SystemRoot, 'System32\WindowsPowerShell\v1.0\powershell.exe')
    $cmdText = '& ''' + $script:ScriptFull + ''''
    $argString = '-NoProfile -ExecutionPolicy Bypass'
    if ($PSVersionTable.PSVersion.Major -ge 3) { $argString = $argString + ' -STA' }
    $argString = $argString + ' -WindowStyle Hidden -Command "' + $cmdText + '"'
    try {
        if ($script:IsAdmin) {
            Start-Process -FilePath $psExe -ArgumentList $argString -ErrorAction Stop
        } else {
            Start-Process -FilePath $psExe -ArgumentList $argString -Verb RunAs -ErrorAction Stop
        }
    } catch {
        Show-Error ('Не удалось перезапустить утилиту: ' + $_.Exception.Message + [Environment]::NewLine + 'Запустите её вручную — язык уже сохранён.')
        return
    }
    $script:ExitRequested = $true
    [void](Save-SettingsFromUi)
    if ($script:Ui['Form'] -ne $null) { $script:Ui['Form'].Close() }
}

function On-PreviewClick {
    $o = Collect-OptionsFromUi
    $lines = Set-NtpConfiguration -Options $o -Preview
    $warn = Get-PeerFlagWarning $o
    $polWarn = Get-PolicyWarning
    if ($polWarn -ne '') {
        if ($warn -ne '') { $warn = $polWarn + [Environment]::NewLine + [Environment]::NewLine + $warn } else { $warn = $polWarn }
    }
    if ($warn -ne '') {
        $all = New-Object System.Collections.ArrayList
        [void]$all.Add($warn)
        foreach ($l in $lines) { [void]$all.Add($l) }
        if ($all.Count -eq 1) { [void]$all.Add('Изменений больше не требуется.') }
        Set-PreviewText $all
    } else {
        Set-PreviewText $lines
    }
    Add-Log ('Предпросмотр: изменений ' + $lines.Count + '. Записи в систему НЕ выполнялись.')
}

function On-ApplyClick {
    if (-not $script:IsAdmin) {
        Show-Error 'Для применения настроек нужны права администратора.'
        return
    }
    $o = Collect-OptionsFromUi
    if ((Get-UiBool 'ChkClient') -and -not $o.ContainsKey('Peers')) {
        if (-not (Ask-Confirm 'Провайдер NTP-клиента включается, но список серверов времени пуст — машине не у кого брать время. Продолжить всё равно?')) { return }
    }
    if (-not (Get-UiBool 'ChkServer')) {
        if (-not (Ask-Confirm 'Раздача времени клиентам будет ВЫКЛЮЧЕНА — клиенты локальной сети перестанут получать время с этой машины. Продолжить?')) { return }
    }
    $lines = Set-NtpConfiguration -Options $o -Preview
    $warn = Get-PeerFlagWarning $o
    $polWarn = Get-PolicyWarning
    if ($polWarn -ne '') {
        if ($warn -ne '') { $warn = $polWarn + [Environment]::NewLine + [Environment]::NewLine + $warn } else { $warn = $polWarn }
    }
    Set-PreviewText $lines
    if ($lines.Count -eq 0) {
        if ($warn -eq '') { Show-Info 'Изменений не требуется: настройки уже соответствуют заданным.' }
        else { Show-Info $warn }
        return
    }
    $text = 'Будут применены изменения:' + [Environment]::NewLine + [Environment]::NewLine + ($lines -join [Environment]::NewLine)
    if ($warn -ne '') { $text = $warn + [Environment]::NewLine + [Environment]::NewLine + $text }
    $text = $text + [Environment]::NewLine + [Environment]::NewLine + 'Будет создана резервная копия настроек (рег-файл) и перезапущена служба времени.' + [Environment]::NewLine + 'Продолжить?'
    if (-not (Ask-Confirm $text 'Подтверждение изменений')) { Add-Log 'Применение отменено пользователем.'; return }
    [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        $applied = Set-NtpConfiguration -Options $o
    } catch {
        [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default
        Show-Error ('Не удалось применить настройки: ' + $_.Exception.Message)
        return
    } finally {
        [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default
    }
    Set-PreviewText $applied
    [void](Save-SettingsFromUi)
    Refresh-StatusView
    Refresh-ServiceView
    if ($script:LastApplyErrors -ne $null -and $script:LastApplyErrors.Count -gt 0) {
        Show-Error ('Часть операций завершилась ошибкой:' + [Environment]::NewLine + ($script:LastApplyErrors -join [Environment]::NewLine) + [Environment]::NewLine + 'Подробности — в журнале.')
    } else {
        Show-Info ('Готово. Применено изменений: ' + $applied.Count + '.' + [Environment]::NewLine + 'Проверьте состояние на вкладке «Состояние».')
    }
}

function On-RecommendedClick {
    $script:Ui['ChkServer'].Checked = $true
    $script:Ui['ChkAllowNonstd'].Checked = $true
    $script:Ui['ChkReliable'].Checked = $true
    $script:Ui['ChkClient'].Checked = $true
    $script:Ui['RadNtp'].Checked = $true
    $script:Ui['ChkFirewall'].Checked = $true
    $script:Ui['ChkPeerFlag'].Checked = $true
    $script:Ui['CmbStartupCfg'].SelectedIndex = 0
    if ($script:Ui['NumPoll'].Value -lt 60 -or $script:Ui['NumPoll'].Value -gt 3600) { $script:Ui['NumPoll'].Value = 300 }
    [void](Save-SettingsFromUi)
    $o = Collect-OptionsFromUi
    $lines = Set-NtpConfiguration -Options $o -Preview
    Set-PreviewText $lines
    Add-Log 'Заполнены рекомендуемые значения. Ничего не применялось — проверьте адрес GPS-сервера и нажмите «ПРИМЕНИТЬ НАСТРОЙКИ».'
    if ([string]$script:Ui['TxtPeers'].Text.Trim() -eq '') {
        Show-Info 'Не забудьте указать адрес GPS-сервера в поле «Серверы времени», например: 192.168.1.50,0x9' + [Environment]::NewLine + 'Флаг 0x9 = клиент + использовать заданный интервал опроса.'
    }
}

function On-SaveSettingsClick {
    if (Save-SettingsFromUi) {
        Add-Log ('Настройки сохранены в файл: ' + $script:SettingsFile)
        Show-Info ('Настройки сохранены:' + [Environment]::NewLine + $script:SettingsFile)
    } else {
        Show-Error 'Не удалось сохранить настройки (проверьте права на папку).'
    }
}

function On-ImportBackupClick {
    if (-not $script:IsAdmin) { Show-Error 'Для импорта настроек нужны права администратора.'; return }
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = 'Выберите файл резервной копии настроек W32Time'
    if ([System.IO.Directory]::Exists($script:BackupDir)) { $dlg.InitialDirectory = $script:BackupDir }
    $dlg.Filter = 'Рег-файлы (*.reg)|*.reg|Все файлы (*.*)|*.*'
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    if (-not (Ask-Confirm ('Импортировать настройки из файла:' + [Environment]::NewLine + $dlg.FileName + [Environment]::NewLine + [Environment]::NewLine + 'Текущие настройки будут перезаписаны, служба времени будет остановлена и запущена заново. Продолжить?'))) { return }
    [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        [void](Backup-W32TimeRegistry)
        $e1 = Stop-TimeService -TimeoutSec 40
        $e2 = Restore-W32TimeRegistry -RegFile $dlg.FileName
        $e3 = Start-TimeService -TimeoutSec 40
    } finally {
        [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default
    }
    if ($e2 -ne '') { Show-Error ('Импорт не удался: ' + $e2); return }
    Add-Log ('Настройки импортированы из ' + $dlg.FileName)
    Refresh-StatusView
    Refresh-ServiceView
    Show-Info 'Настройки импортированы, служба времени перезапущена.'
}

function On-FirewallShowClick {
    $info = Get-NtpFirewallRuleInfo
    if ($info.Exists) {
        Set-OutputText ('--- Правило брандмауэра ---' + [Environment]::NewLine + $info.Text)
    } else {
        Set-OutputText ('--- Правило брандмауэра ---' + [Environment]::NewLine + 'Правило "' + $script:FwRuleName + '" не найдено.' + [Environment]::NewLine + $info.Text)
    }
}

function On-FirewallAddClick {
    if (-not $script:IsAdmin) { Show-Error 'Для изменения брандмауэра нужны права администратора.'; return }
    if ((Get-NtpFirewallRuleInfo).Exists) { Show-Info 'Правило уже существует.'; return }
    $r = Add-NtpFirewallRule
    if ($r.ExitCode -eq 0) {
        Add-Log ('Брандмауэр: добавлено правило входящего UDP ' + $script:NtpPort)
        Set-OutputText ('--- Правило брандмауэра добавлено ---' + [Environment]::NewLine + (Get-ExeText $r -WithErrors))
        Refresh-StatusView
    } else {
        Show-Error ('Не удалось добавить правило:' + [Environment]::NewLine + (Get-ExeText $r -WithErrors))
    }
}

function On-FirewallRemoveClick {
    if (-not $script:IsAdmin) { Show-Error 'Для изменения брандмауэра нужны права администратора.'; return }
    if (-not (Ask-Confirm ('Удалить правило входящего UDP ' + $script:NtpPort + '? Клиенты локальной сети могут перестать получать время.'))) { return }
    $r = Remove-NtpFirewallRule
    if ($r.ExitCode -eq 0) {
        Add-Log ('Брандмауэр: правило UDP ' + $script:NtpPort + ' удалено')
        Refresh-StatusView
    } else {
        Show-Error ('Не удалось удалить правило:' + [Environment]::NewLine + (Get-ExeText $r -WithErrors))
    }
}

function On-CmdStatusClick {
    Set-OutputText ('--- w32tm /query /status ---' + [Environment]::NewLine + (Get-ExeText (Invoke-W32tm '/query /status' 60) -WithErrors))
}

function On-CmdConfigClick {
    Set-OutputText ('--- w32tm /query /configuration ---' + [Environment]::NewLine + (Get-ExeText (Invoke-W32tm '/query /configuration' 60) -WithErrors))
}

function On-CmdPeersClick {
    Set-OutputText ('--- w32tm /query /peers ---' + [Environment]::NewLine + (Get-ExeText (Invoke-W32tm '/query /peers' 60) -WithErrors))
}

function On-CmdStripClick {
    $srv = [string]$script:Ui['TxtCheckServer'].Text.Trim()
    if ($srv -eq '') { $srv = '127.0.0.1' }
    [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        $r = Invoke-W32tm ('/stripchart /computer:' + $srv + ' /samples:5') 90
    } finally {
        [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default
    }
    Set-OutputText ('--- w32tm /stripchart /computer:' + $srv + ' /samples:5 ---' + [Environment]::NewLine + (Get-ExeText $r -WithErrors))
}

function On-CmdEventsClick {
    $ev = @(Get-W32TimeEvents -Max 10)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('--- Последние события источника W32Time (журнал System) ---')
    if ($ev.Count -eq 0) { [void]$sb.AppendLine('Записей нет. Это нормально, если служба давно работает без сбоев.') }
    foreach ($e in $ev) {
        [void]$sb.AppendLine($e.Time.ToString('yyyy-MM-dd HH:mm:ss') + '  ID ' + $e.Id + '  ' + $e.Source)
        $msg = [string]$e.Message
        $msg = $msg -replace "`r?`n", ' '
        if ($msg.Length -gt 400) { $msg = $msg.Substring(0, 400) + '...' }
        [void]$sb.AppendLine('    ' + $msg)
    }
    Set-OutputText ($sb.ToString())
}

function On-CmdResyncClick {
    if (-not $script:IsAdmin) { Show-Error 'Для команды /resync нужны права администратора.'; return }
    $r = Invoke-W32tm '/resync' 60
    Set-OutputText ('--- w32tm /resync (код ' + $r.ExitCode + ') ---' + [Environment]::NewLine + (Get-ExeText $r -WithErrors))
    Add-Log ('w32tm /resync -> код ' + $r.ExitCode)
    Refresh-StatusView
}

function On-CmdRediscoverClick {
    if (-not $script:IsAdmin) { Show-Error 'Для команды /resync нужны права администратора.'; return }
    $r = Invoke-W32tm '/resync /rediscover' 90
    Set-OutputText ('--- w32tm /resync /rediscover (код ' + $r.ExitCode + ') ---' + [Environment]::NewLine + (Get-ExeText $r -WithErrors))
    Add-Log ('w32tm /resync /rediscover -> код ' + $r.ExitCode)
    Refresh-StatusView
}

function On-CmdPortClick {
    $items = @()
    foreach ($i0 in @(Get-UdpListeners $script:NtpPort)) { if ($i0 -ne $null) { $items += $i0 } }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('--- Кто слушает UDP ' + $script:NtpPort + ' ---')
    if ($items.Count -eq 0) { [void]$sb.AppendLine('Никто не слушает — NTP-сервер не отвечает клиентам.') }
    foreach ($i in $items) {
        [void]$sb.AppendLine('[' + $i.Address + ']:' + $i.Port + '  PID ' + $i.ProcessId + '  ' + $i.Process)
    }
    $snap = Get-ServiceSnapshot
    [void]$sb.AppendLine('PID службы времени (w32time): ' + $snap.ProcessId)
    Set-OutputText ($sb.ToString())
}

function On-ClearOutputClick { $script:Ui['OutBox'].Clear() }

function On-SaveOutputClick {
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Title = 'Сохранить вывод в файл'
    $dlg.Filter = 'Текстовые файлы (*.txt)|*.txt|Все файлы (*.*)|*.*'
    $dlg.FileName = 'NtpManager-output-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.txt'
    if ([System.IO.Directory]::Exists($script:WorkDir)) { $dlg.InitialDirectory = $script:WorkDir }
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    try {
        [System.IO.File]::WriteAllText($dlg.FileName, $script:Ui['OutBox'].Text, (New-Object System.Text.UTF8Encoding($false)))
        Add-Log ('Вывод сохранён в ' + $dlg.FileName)
    } catch {
        Show-Error ('Не удалось сохранить файл: ' + $_.Exception.Message)
    }
}

function On-CopyOutputClick {
    try {
        [System.Windows.Forms.Clipboard]::SetText($script:Ui['OutBox'].Text)
        Add-Log 'Вывод скопирован в буфер обмена.'
    } catch {
        Show-Error ('Не удалось скопировать: ' + $_.Exception.Message)
    }
}

function On-TextReportClick {
    [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        $text = Get-TextReport -RunSntpCheck
    } finally {
        [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default
    }
    Set-OutputText $text
    if ($script:Ui['Tabs'] -ne $null) { $script:Ui['Tabs'].SelectedIndex = 3 }
}

function On-HelpClick {
    $nl = [Environment]::NewLine
    $t = New-Object System.Text.StringBuilder
    [void]$t.AppendLine('NTP Manager ' + $script:Ver + ' — краткая справка')
    [void]$t.AppendLine('')
    [void]$t.AppendLine('НАЗНАЧЕНИЕ: раздавать время клиентам локальной сети (NTP-сервер) и брать время')
    [void]$t.AppendLine('у GPS-сервера (NTP-клиент), а также следить за состоянием службы времени Windows.')
    [void]$t.AppendLine('')
    [void]$t.AppendLine('ВКЛАДКА «НАСТРОЙКА» — что значит каждое поле:')
    [void]$t.AppendLine(' • Включить провайдер NtpServer — машина отвечает на NTP-запросы клиентов сети.')
    [void]$t.AppendLine(' • Нестандартные комбинации режимов — отвечать и тем клиентам, кто работает не строго по стандарту.')
    [void]$t.AppendLine(' • Надёжный источник времени (AnnounceFlags = 5) — так помечают сервер времени в домене.')
    [void]$t.AppendLine(' • Включить провайдер NtpClient — машина берёт время у сервера, указанного ниже.')
    [void]$t.AppendLine(' • Тип источника: «Ручной список (NTP)» — то, что нужно для GPS; «Иерархия домена» — время из Active Directory.')
    [void]$t.AppendLine(' • Адрес GPS-сервера — достаточно ввести IP (192.168.1.50): галочка рядом сама допишет флаг ,0x9.')
    [void]$t.AppendLine('   Флаг 0x9 = 0x1 (использовать заданный интервал опроса) + 0x8 (режим клиента).')
    [void]$t.AppendLine('   Без флага служба опрашивает источник по своему расписанию (64–1024 с), и поле интервала не действует.')
    [void]$t.AppendLine(' • Интервал опроса, с (SpecialPollInterval) — как часто спрашивать GPS: 60–900 в локальной сети.')
    [void]$t.AppendLine(' • Тип запуска службы — для сервера времени нужен «Автоматически».')
    [void]$t.AppendLine(' • Разрешить входящий UDP 123 — правило брандмауэра, без него клиенты время не получат.')
    [void]$t.AppendLine(' • Макс. разовое смещение часов, с (MaxAllowedPhaseOffset) — если расхождение больше, служба не')
    [void]$t.AppendLine('   станет догонять время разом, а запишет ошибку. Пусто — не менять (по умолчанию 300).')
    [void]$t.AppendLine(' • EventLogFlags — подробность записей службы в журнале System: 0..3. Пусто — не менять.')
    [void]$t.AppendLine(' • «Проверить изменения» показывает список правок и ничего не меняет в системе.')
    [void]$t.AppendLine('')
    [void]$t.AppendLine('ВКЛАДКА «ДИАГНОСТИКА» — что делают кнопки (это обёртки над w32tm):')
    [void]$t.AppendLine(' • Состояние синхронизации — w32tm /query /status: источник, последняя удачная синхронизация, смещение.')
    [void]$t.AppendLine(' • Действующие настройки — /query /configuration: параметры, которые служба применяет сейчас.')
    [void]$t.AppendLine(' • Источники времени — /query /peers: список источников и их состояние.')
    [void]$t.AppendLine(' • Замеры с сервера (5) — /stripchart: d: задержка, o: смещение часов.')
    [void]$t.AppendLine(' • События службы — последние записи службы времени из журнала System.')
    [void]$t.AppendLine(' • Синхронизировать сейчас — /resync; Перечитать источники — /resync /rediscover.')
    [void]$t.AppendLine(' • Кто слушает порт 123 — какой процесс реально принял UDP 123 (важно: чужой процесс на порту')
    [void]$t.AppendLine('   означает, что встроенный сервер не сможет отвечать клиентам).')
    [void]$t.AppendLine(' • Правило брандмауэра: показать / Разрешить UDP 123 / Удалить правило.')
    [void]$t.AppendLine(' • Проверка 127.0.0.1 — отвечает ли NTP-сервер на этой машине; «Проверить этот сервер»')
    [void]$t.AppendLine('   с клиентской машины — доступен ли сервер по сети вместе с брандмауэром.')
    [void]$t.AppendLine('')
    [void]$t.AppendLine('ПРОЧЕЕ:')
    [void]$t.AppendLine(' • F5 — обновить состояние. Двойной щелчок по значку в области уведомлений — показать окно.')
    [void]$t.AppendLine(' • Любой элемент окна: подсказка при наведении курсора мыши.')
    [void]$t.AppendLine(' • Журнал: ' + $script:LogFile)
    [void]$t.AppendLine(' • Настройки: ' + $script:SettingsFile)
    [void]$t.AppendLine(' • Резервные копии: ' + $script:BackupDir)
    Show-Info $t.ToString() 'Справка NTP Manager'
}

function On-OpenLogClick {
    if ([System.IO.File]::Exists($script:LogFile)) {
        try { Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $script:LogFile + '"') } catch { }
    } else {
        Show-Info 'Файл журнала ещё не создан.'
    }
}

function On-OpenFolderClick {
    try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $script:WorkDir + '"') } catch { }
}

function On-ClearLogClick {
    $box = $script:Ui['LogBox']
    if ($box -ne $null) { $box.Clear() }
}

function On-TrayCheckChanged {
    $tray = $script:Ui['Tray']
    if ($tray -eq $null) { return }
    $tray.Visible = (Get-UiBool 'ChkTray')
}

function On-RefreshPeriodChanged {
    $t = $script:Ui['Timer']
    $n = $script:Ui['NumRefresh']
    if ($t -ne $null -and $n -ne $null) { $t.Interval = [int]($n.Value * 1000) }
}

function On-TimerTick {
    $script:TickCount = $script:TickCount + 1
    $sec = [int]$script:Ui['NumRefresh'].Value
    if ($sec -lt 5) { $sec = 15 }
    # Полная проверка (брандмауэр, события, порт 123) — раз в 10 минут или по кнопке «Обновить».
    $everyFull = [int][Math]::Ceiling(600 / $sec)
    if ($everyFull -lt 1) { $everyFull = 1 }
    $doFull = (($script:TickCount % $everyFull) -eq 0)
    # Опрос своего NTP-сервера — раз в 5 минут и только если включён в «Мониторинге».
    $checkSntp = $false
    if (Get-UiBool 'ChkMonitorSntp') {
        $everySntp = [int][Math]::Ceiling(300 / $sec)
        if ($everySntp -lt 1) { $everySntp = 1 }
        if (($script:TickCount % $everySntp) -eq 0) { $checkSntp = $true }
    }
    if ($checkSntp) {
        $q = Invoke-NtpCheck -Server '127.0.0.1' -Samples 1 -TimeoutMs 1200
        $script:SntpLocal = $q
        $st = Get-NtpConfigState
        if ($null -ne $st.ServerEnabled -and [int]$st.ServerEnabled -eq 1 -and -not $q.Success) {
            Add-Log ('NTP-сервер не отвечает на запрос: ' + $q.Error) 'WARN'
            Show-TrayBalloon 'NTP Manager' 'NTP-сервер не отвечает на запросы — проверьте состояние'
        }
    }
    if ((Get-UiBool 'ChkAutoRefresh') -or $doFull -or $checkSntp) {
        Refresh-StatusView -Quiet -Full:$doFull
    }
    Refresh-ServiceView -Fast
}

function On-FormResize {
    $f = $script:Ui['Form']
    if ($f -eq $null) { return }
    if ($f.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized -and (Get-UiBool 'ChkMinToTray')) {
        $f.Hide()
        if ($script:Ui['Tray'] -ne $null) { $script:Ui['Tray'].Visible = $true }
    }
}

function On-FormKeyDown {
    param($sender, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::F5) {
        On-RefreshClick
        $e.Handled = $true
    }
}

function On-TrayShowClick {
    $f = $script:Ui['Form']
    if ($f -eq $null) { return }
    $f.Show()
    if ($f.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) { $f.WindowState = [System.Windows.Forms.FormWindowState]::Normal }
    [void]$f.Activate()
}

function On-TrayExitClick {
    $script:ExitRequested = $true
    $f = $script:Ui['Form']
    if ($f -ne $null) { $f.Close() }
}

function On-FormClosing {
    param($sender, $e)
    if (-not $script:ExitRequested -and (Get-UiBool 'ChkMinToTray')) {
        $e.Cancel = $true
        $sender.Hide()
        if ($script:Ui['Tray'] -ne $null) { $script:Ui['Tray'].Visible = $true }
        Add-Log 'Окно свёрнуто в область уведомлений (утилита продолжает мониторинг).'
        return
    }
    [void](Save-SettingsFromUi)
    $script:ExitRequested = $true
}

# ---------------------------------------------------------------------------
# Запуск окна
# ---------------------------------------------------------------------------
function Ensure-Elevated {
    $needRelaunch = $false
    $useSta = ($PSVersionTable.PSVersion.Major -ge 3)
    if (-not $script:IsAdmin) { $needRelaunch = $true }
    try {
        $ap = [System.Threading.Thread]::CurrentThread.GetApartmentState()
        if ($useSta -and $ap -ne [System.Threading.ApartmentState]::STA) { $needRelaunch = $true }
    } catch { }
    if (-not $needRelaunch) { return $true }
    if ($script:ScriptFull -eq '') { return $true }
    $psExe = [System.IO.Path]::Combine($env:SystemRoot, 'System32\WindowsPowerShell\v1.0\powershell.exe')
    $cmdText = '& ''' + $script:ScriptFull + ''''
    $argString = '-NoProfile -ExecutionPolicy Bypass'
    if ($useSta) { $argString = $argString + ' -STA' }
    $argString = $argString + ' -WindowStyle Hidden -Command "' + $cmdText + '"'
    try {
        Start-Process -FilePath $psExe -ArgumentList $argString -Verb RunAs -ErrorAction Stop
        return $false
    } catch {
        Add-Log ('Повышение прав не выполнено (' + $_.Exception.Message + '). Работаем в режиме просмотра.') 'WARN'
        return $true
    }
}

function Invoke-Gui {
    Add-WinForms
    [System.Windows.Forms.Application]::EnableVisualStyles()
    if (-not (Ensure-Elevated)) { return 0 }
    Add-Log ('Запуск графического интерфейса. Права администратора: ' + $script:IsAdmin + ', PowerShell ' + $PSVersionTable.PSVersion.ToString())
    $form = Build-Form
    Load-SettingsIntoUi
    if (-not $script:IsAdmin) {
        Add-Log 'ВНИМАНИЕ: утилита запущена без прав администратора — доступен только просмотр.' 'WARN'
    }
    Refresh-ServiceView
    Refresh-StatusView -Full
    if ($script:Ui['Timer'] -ne $null) { $script:Ui['Timer'].Start() }
    [void]$form.ShowDialog()
    if ($script:Ui['Timer'] -ne $null) { $script:Ui['Timer'].Stop() }
    if ($script:Ui['Tray'] -ne $null) { $script:Ui['Tray'].Visible = $false; $script:Ui['Tray'].Dispose() }
    [void](Save-SettingsFromUi)
    Add-Log 'Работа завершена.'
    return 0
}

# ===========================================================================
# ТОЧКА ВХОДА (ENTRY POINT)
# ===========================================================================
$script:ExitRequested = $false
$script:LastState     = ''
$script:LastSummary   = $null
$script:SntpLocal     = $null
$script:SntpPeer      = $null
$script:SntpPeerServer = ''
$script:TickCount     = 0
$script:LastApplyErrors = $null
$script:SntpStackOk   = $null
$script:SntpStackError = ''

Initialize-Language -Requested $Language

$exitCode = 0
if ($Help) {
    Show-HelpText
    $exitCode = 0
} elseif ($Report) {
    $exitCode = Invoke-ReportMode -ReportFile $ReportFile
} elseif ($RestoreService) {
    $exitCode = Invoke-RestoreMode
} elseif ($Apply) {
    $exitCode = Invoke-ApplyMode
} else {
    $exitCode = Invoke-Gui
}
exit $exitCode
