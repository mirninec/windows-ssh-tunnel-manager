#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent

#Include ./utils/Utils.ahk
#Include ./utils/Logger.ahk
#Include ./utils/Tunnel.ahk

; ============================================================
; Конфигурация приложения
; ============================================================
global Config := {
    ; --- Параметры туннеля ---
    TargetHost: "",
    TargetUser: "",
    TargetPort: 22,
    LocalPort: 1080,
    AuthMode: "key",   ; "key" | "password"
    SshKey: "",
    Password: "",
    PlinkExe: A_ScriptDir "\plink.exe",
    ; --- Поведение ---
    CheckIntervalMs: 60000,
    StartupWaitMs: 4000,
    MaxRetry: 5
}

; ============================================================
; Состояние приложения
; ============================================================
global State := {
    RetryCount: 0,
    GaveUp: false,
    TrayState: "",
    MutexHwnd: 0,
    PidFile: A_Temp "\ssh-tunnel-monitor.pid"
}

; ============================================================
; Пути к файлам
; ============================================================
global ConfigFile := A_ScriptDir "\ssh-tunnel-monitor.ini"
global LogFile := A_ScriptDir "\ssh-tunnel-monitor.log"

; ============================================================
; Инициализация логгера
; ============================================================
Logger.File := LogFile
Logger.MinLevel := "DEBUG"   ; "DEBUG" | "INFO" | "WARN" | "ERROR"
Logger.MaxSize := 1048576
Logger.MaxBackups := 5

; ============================================================
; Связываем Tunnel с Config и State
; ============================================================
Tunnel.Config := Config
Tunnel.State := State

; ============================================================
; Mutex — защита от повторного запуска
; ============================================================
State.MutexHwnd := CreateMutexSingleInstance("Local\SSH_TUNNEL_AHK_V2_SINGLE_INSTANCE")

if !State.MutexHwnd {
    MsgBox("Скрипт уже запущен.", "SSH Tunnel", "Icon!")
    ExitApp
}

; ============================================================
; Трей
; ============================================================
A_TrayMenu.Delete()
A_TrayMenu.Add("✅ Проверить / восстановить", TrayEnsureTunnel)
A_TrayMenu.Add("🔄 Перезапустить туннель", TrayRestartTunnel)
A_TrayMenu.Add("ℹ️ Статус", TrayShowStatus)
A_TrayMenu.Add()
A_TrayMenu.Add("⚙️ Настройки", TrayOpenSettings)
A_TrayMenu.Add("📝 Открыть лог", TrayOpenLog)
A_TrayMenu.Add("Запускать при входе в систему", TrayToggleStartup)
A_TrayMenu.Add()
A_TrayMenu.Add("Выход", TrayExit)

UpdateStartupMenuState()
A_IconTip := "SSH Tunnel Monitor"

; ============================================================
; Старт
; ============================================================
AppLog("INFO", "=== Скрипт запущен ===")

if !LoadConfig() {
    if !RunSetupWizard() {
        AppLog("WARN", "Настройка отменена пользователем. Выход.")
        if State.MutexHwnd
            DllCall("CloseHandle", "Ptr", State.MutexHwnd)
        ExitApp
    }
}

Tunnel._SetTrayState("yellow")
Tunnel.Ensure()
SetTimer((*) => Tunnel.Ensure(), Config.CheckIntervalMs)

return

; ============================================================
; Загрузка конфигурации из INI
; ============================================================
LoadConfig() {
    global ConfigFile, Config

    if !FileExist(ConfigFile)
        return false

    Config.TargetPort := IniRead(ConfigFile, "Tunnel", "TargetSshPort", "")
    Config.TargetUser := IniRead(ConfigFile, "Tunnel", "TargetUser", "")
    Config.TargetHost := IniRead(ConfigFile, "Tunnel", "TargetHost", "")
    Config.LocalPort := IniRead(ConfigFile, "Tunnel", "LocalPort", "")
    Config.SshKey := IniRead(ConfigFile, "Tunnel", "SshKey", "")
    Config.Password := IniRead(ConfigFile, "Tunnel", "SshPassword", "")
    Config.AuthMode := IniRead(ConfigFile, "Tunnel", "AuthMode", "key")
    Config.PlinkExe := IniRead(ConfigFile, "Tunnel", "PlinkExe",
        A_ScriptDir "\plink.exe")

    if (Config.TargetUser = "" || Config.TargetHost = ""
        || Config.LocalPort = "" || Config.TargetPort = "")
        return false

    Config.TargetPort := Integer(Config.TargetPort)
    Config.LocalPort := Integer(Config.LocalPort)

    AppLog("INFO", "Конфиг загружен из: " ConfigFile)
    return true
}

; ============================================================
; Сохранение конфигурации в INI
; ============================================================
SaveConfig() {
    global ConfigFile, Config

    IniWrite(Config.TargetPort, ConfigFile, "Tunnel", "TargetSshPort")
    IniWrite(Config.TargetUser, ConfigFile, "Tunnel", "TargetUser")
    IniWrite(Config.TargetHost, ConfigFile, "Tunnel", "TargetHost")
    IniWrite(Config.LocalPort, ConfigFile, "Tunnel", "LocalPort")
    IniWrite(Config.SshKey, ConfigFile, "Tunnel", "SshKey")
    IniWrite(Config.Password, ConfigFile, "Tunnel", "SshPassword")
    IniWrite(Config.AuthMode, ConfigFile, "Tunnel", "AuthMode")
    IniWrite(Config.PlinkExe, ConfigFile, "Tunnel", "PlinkExe")

    AppLog("INFO", "Конфиг сохранён в: " ConfigFile)
}

; ============================================================
; Мастер настройки
; ============================================================
RunSetupWizard(isEdit := false) {
    global Config, State

    title := isEdit ? "Настройки SSH Tunnel" : "Первый запуск — настройка SSH Tunnel"

    wiz := Gui("+AlwaysOnTop", title)
    wiz.SetFont("s10", "Segoe UI")
    wiz.MarginX := 16
    wiz.MarginY := 12

    wiz.AddText("w460", "Укажите параметры SSH-туннеля.")

    ; --- Хост ---
    wiz.AddText("w460 y+10", "Хост / IP сервера:")
    edHost := wiz.AddEdit("w460 y+4", Config.TargetHost)

    ; --- SSH-порт ---
    wiz.AddText("w460 y+8", "SSH-порт сервера:")
    edPort := wiz.AddEdit("w200 y+4",
        String(Config.TargetPort != 0 ? Config.TargetPort : 22))

    ; --- Пользователь ---
    wiz.AddText("w460 y+8", "Имя пользователя SSH:")
    edUser := wiz.AddEdit("w460 y+4", Config.TargetUser)

    ; --- Локальный порт ---
    wiz.AddText("w460 y+8", "Локальный порт SOCKS5 (например 1080):")
    edLocal := wiz.AddEdit("w200 y+4",
        String(Config.LocalPort != 0 ? Config.LocalPort : 1080))

    ; --- Метод аутентификации ---
    wiz.AddText("w460 y+14", "Метод аутентификации:")
    rbKey := wiz.AddRadio("w460 y+6 Group",
        "SSH-ключ (используется системный ssh.exe)")
    rbPass := wiz.AddRadio("w460 y+4",
        "Логин / Пароль (используется plink.exe из папки скрипта)")

    if (Config.AuthMode = "password")
        rbPass.Value := 1
    else
        rbKey.Value := 1

    ; --- Секция SSH-ключа ---
    grpKey := wiz.AddGroupBox("w460 y+10 h72", "Параметры SSH-ключа")
    wiz.AddText("xp+10 yp+22 w320", "Путь к файлу ключа:")
    edKey := wiz.AddEdit("xp w320 y+4", Config.SshKey)
    btnBrowse := wiz.AddButton("x+8 yp w112", "Обзор...")
    warnKey := wiz.AddText("xp-320 y+4 w440 cRed", "")

    ; --- Секция plink / пароль ---
    grpPass := wiz.AddGroupBox("w460 y+10 h130", "Параметры plink.exe / пароль")
    wiz.AddText("xp+10 yp+22 w440", "Путь к plink.exe:")
    edPlink := wiz.AddEdit("w330 y+4",
        FileExist(Config.PlinkExe) ? Config.PlinkExe : "")
    btnBrowsePlink := wiz.AddButton("x+8 yp w112", "Обзор...")
    warnPlink := wiz.AddText("xp-330 y+4 w440 cRed", "")
    wiz.AddText("w440 y+6", "Пароль SSH:")
    edPass := wiz.AddEdit("w460 y+4 Password", Config.Password)

    btnFirstLogin := wiz.AddButton("w440 y+10",
        "🔑  Войти на удалённый сервер (принять fingerprint)...")
    btnFirstLogin.OnEvent("Click",
        (*) => DoFirstLogin(edPlink, edHost, edPort, edUser, edPass, wiz))

    wiz.AddText("w460 y+14 0x10")
    btnSave := wiz.AddButton("w100 y+10 Default", "Сохранить")
    btnCancel := wiz.AddButton("x+10 yp w100", "Отмена")

    ; --- Включение/выключение секций ---
    UpdateSections(*) {
        useKey := rbKey.Value
        edKey.Enabled := useKey
        btnBrowse.Enabled := useKey
        edPlink.Enabled := !useKey
        btnBrowsePlink.Enabled := !useKey
        edPass.Enabled := !useKey
        btnFirstLogin.Enabled := !useKey
    }

    rbKey.OnEvent("Click", UpdateSections)
    rbPass.OnEvent("Click", UpdateSections)
    UpdateSections()

    ; --- Обработчики полей ---
    btnBrowse.OnEvent("Click",
        (*) => BrowseKey(edKey, warnKey))
    edKey.OnEvent("Change",
        (*) => ValidateKeyField(edKey, warnKey))
    btnBrowsePlink.OnEvent("Click",
        (*) => BrowsePlink(edPlink, warnPlink))
    edPlink.OnEvent("Change",
        (*) => ValidatePlinkField(edPlink, warnPlink))

    btnSave.OnEvent("Click", SaveHandler)
    btnCancel.OnEvent("Click", (*) => wiz.Hide())
    wiz.OnEvent("Close", (*) => wiz.Hide())

    if (Config.SshKey != "")
        ValidateKeyField(edKey, warnKey)
    ValidatePlinkField(edPlink, warnPlink)

    saved := false

    ; --- Сохранение ---
    SaveHandler(*) {
        host := Trim(edHost.Value)
        port := Trim(edPort.Value)
        user := Trim(edUser.Value)
        lport := Trim(edLocal.Value)
        key := Trim(edKey.Value)
        plink := Trim(edPlink.Value)
        pass := edPass.Value
        mode := rbKey.Value ? "key" : "password"

        errors := _CollectValidationErrors(
            host, port, user, lport, key, plink, pass, mode)

        if (errors != "") {
            MsgBox("Исправьте ошибки:`n`n" errors, "Ошибка", "Icon! 48")
            return
        }

        Config.TargetPort := Integer(port)
        Config.TargetUser := user
        Config.TargetHost := host
        Config.LocalPort := Integer(lport)
        Config.AuthMode := mode

        if (mode = "key") {
            Config.SshKey := key
            Config.Password := ""
        } else {
            Config.SshKey := ""
            Config.Password := pass
            Config.PlinkExe := plink
        }

        State.RetryCount := 0
        State.GaveUp := false

        SaveConfig()
        saved := true
        wiz.Hide()
    }

    wiz.Show()

    while wiz.Hwnd && WinExist("ahk_id " wiz.Hwnd)
        Sleep(100)

    return saved
}

; --- Валидация полей мастера настройки ---
_CollectValidationErrors(host, port, user, lport, key, plink, pass, mode) {
    errors := ""

    if (host = "")
        errors .= "• Хост не может быть пустым.`n"
    if !IsValidPort(port)
        errors .= "• SSH-порт должен быть числом от 1 до 65535.`n"
    if (user = "")
        errors .= "• Имя пользователя не может быть пустым.`n"
    if !IsValidPort(lport)
        errors .= "• Локальный порт должен быть числом от 1 до 65535.`n"

    if (mode = "key") {
        if (key != "" && !FileExist(key))
            errors .= "• Файл SSH-ключа не найден.`n"
    } else {
        if (plink = "")
            errors .= "• Укажите путь к plink.exe.`n"
        else if !FileExist(plink)
            errors .= "• Файл plink.exe не найден по указанному пути.`n"
        if (pass = "")
            errors .= "• Пароль не может быть пустым при выборе режима логин/пароль.`n"
    }

    return errors
}

; ============================================================
; Первый интерактивный вход через plink
; ============================================================
DoFirstLogin(edPlink, edHost, edPort, edUser, edPass, ownerGui) {
    plinkPath := Trim(edPlink.Value)
    host := Trim(edHost.Value)
    port := Trim(edPort.Value)
    user := Trim(edUser.Value)
    pass := edPass.Value

    errors := ""
    if (plinkPath = "")
        errors .= "• Укажите путь к plink.exe.`n"
    else if !FileExist(plinkPath)
        errors .= "• Файл plink.exe не найден: " plinkPath "`n"
    if (host = "")
        errors .= "• Укажите хост сервера.`n"
    if !IsValidPort(port)
        errors .= "• Укажите корректный SSH-порт.`n"
    if (user = "")
        errors .= "• Укажите имя пользователя.`n"

    if (errors != "") {
        MsgBox("Сначала заполните поля:`n`n" errors, "Первый вход", "Icon! 48")
        return
    }

    ; --- Инструкция ---
    instrGui := Gui("+AlwaysOnTop +Owner" ownerGui.Hwnd, "Первый вход — инструкция")
    instrGui.SetFont("s10", "Segoe UI")
    instrGui.MarginX := 16
    instrGui.MarginY := 14

    instrGui.AddText("w440", "Сейчас откроется окно командной строки с подключением к серверу.")
    instrGui.AddText("w440 y+8", "Выполните следующие шаги:")
    instrGui.AddText("w440 y+6",
        "  1. Дождитесь вопроса о fingerprint сервера:`n"
        . "     Store key in cache? (y/n, Return cancels connection, i for more info)`n"
        . "`n"
        . "  2. Введите  y  и нажмите Enter.`n"
        . "`n"
        . "  3. Введите пароль, если потребуется, и убедитесь,`n"
        . "     что вход прошёл успешно (появится приглашение shell).`n"
        . "`n"
        . "  4. Введите  exit  и нажмите Enter, чтобы закрыть сессию.")

    instrGui.AddText("w440 y+10 cGray",
        pass != ""
            ? "ℹ Пароль будет передан автоматически через -pw."
            : "ℹ Пароль не задан — введите его вручную в открывшемся окне.")

    instrGui.AddText("w440 y+14 0x10")
    btnGo := instrGui.AddButton("w120 y+10 Default", "Продолжить →")
    btnCancel := instrGui.AddButton("x+10 yp w100", "Отмена")

    proceed := false
    btnGo.OnEvent("Click", (*) => (proceed := true, instrGui.Hide()))
    btnCancel.OnEvent("Click", (*) => instrGui.Hide())
    instrGui.OnEvent("Close", (*) => instrGui.Hide())

    instrGui.Show()
    while instrGui.Hwnd && WinExist("ahk_id " instrGui.Hwnd)
        Sleep(50)

    if !proceed
        return

    ; --- Строим команду ---
    if (pass != "") {
        safePass := StrReplace(pass, '"', '\"')
        plinkCmd := Format('"{1}" -ssh -P {2} -l "{3}" -pw "{4}" {5}',
            plinkPath, port, user, safePass, host)
    } else {
        plinkCmd := Format('"{1}" -ssh -P {2} -l "{3}" {4}',
            plinkPath, port, user, host)
    }

    cmdLine := Format(
        'cmd.exe /K "title SSH Tunnel — первый вход && echo. && '
        . 'echo   Введите y на вопрос о fingerprint, затем войдите и наберите exit && '
        . 'echo. && {1}"',
        plinkCmd
    )

    AppLog("INFO", "DoFirstLogin: запускаем интерактивный plink")
    AppLog("DEBUG", "DoFirstLogin cmd (пароль скрыт): "
        . StrReplace(cmdLine, pass != "" ? pass : "NOPASS", "***"))

    try {
        Run(cmdLine, , "")
    } catch as e {
        MsgBox("Не удалось запустить cmd.exe:`n" e.Message, "Ошибка", "Icon! 48")
        AppLog("ERROR", "DoFirstLogin: Run() не удался — " e.Message)
        return
    }

    Sleep(800)

    ; --- Ожидание подтверждения ---
    afterGui := Gui("+AlwaysOnTop +Owner" ownerGui.Hwnd, "Первый вход — ожидание")
    afterGui.SetFont("s10", "Segoe UI")
    afterGui.MarginX := 16
    afterGui.MarginY := 14

    afterGui.AddText("w380",
        "Окно подключения открыто.`n`n"
        . "После того как примете fingerprint и убедитесь,`n"
        . "что вход прошёл успешно — закройте то окно`n"
        . "и нажмите кнопку ниже.")

    afterGui.AddText("w380 y+14 0x10")
    btnDone := afterGui.AddButton("w160 y+10 Default", "Готово, fingerprint принят")
    btnDone.OnEvent("Click", (*) => afterGui.Hide())
    afterGui.OnEvent("Close", (*) => afterGui.Hide())

    afterGui.Show()
    while afterGui.Hwnd && WinExist("ahk_id " afterGui.Hwnd)
        Sleep(50)

    AppLog("INFO", "DoFirstLogin: пользователь подтвердил принятие fingerprint")
    TrayTip("Fingerprint сохранён. Теперь туннель будет подключаться автоматически.",
        "SSH Tunnel", "1")
}

; ============================================================
; Вспомогательные функции GUI
; ============================================================
BrowseKey(edKey, warnKey) {
    path := FileSelect("3", "", "Выберите файл SSH-ключа", "Все файлы (*.*)")
    if (path != "") {
        edKey.Value := path
        ValidateKeyField(edKey, warnKey)
    }
}

ValidateKeyField(edKey, warnKey) {
    key := Trim(edKey.Value)
    if (key = "") {
        warnKey.Value := ""
        return
    }
    if !FileExist(key) {
        warnKey.Opt("cRed")
        warnKey.Value := "⚠ Файл не найден: " key
    } else {
        warnKey.Opt("cGreen")
        warnKey.Value := "✓ Файл найден"
    }
}

BrowsePlink(edPlink, warnPlink) {
    path := FileSelect("3", A_ScriptDir, "Выберите plink.exe",
        "Исполняемые файлы (*.exe)")
    if (path != "") {
        edPlink.Value := path
        ValidatePlinkField(edPlink, warnPlink)
    }
}

ValidatePlinkField(edPlink, warnPlink) {
    path := Trim(edPlink.Value)
    if (path = "") {
        warnPlink.Value := ""
        return
    }
    if !FileExist(path) {
        warnPlink.Opt("cRed")
        warnPlink.Value := "⚠ Файл не найден: " path
    } else {
        warnPlink.Opt("cGreen")
        warnPlink.Value := "✓ Файл найден"
    }
}

; ============================================================
; Обработчики трея
; ============================================================
TrayEnsureTunnel(*) {
    State.RetryCount := 0
    State.GaveUp := false
    Tunnel.Ensure(true)
}

TrayRestartTunnel(*) {
    State.RetryCount := 0
    State.GaveUp := false
    Tunnel.Restart(true)
}

TrayShowStatus(*) {
    ShowStatus()
}

TrayOpenSettings(*) {
    RunSetupWizard(true)
}

TrayOpenLog(*) {
    global LogFile
    if FileExist(LogFile)
        Run('notepad.exe "' LogFile '"')
    else
        MsgBox("Лог-файл пока не создан.", "SSH Tunnel", "Iconi")
}

TrayExit(*) {
    AppLog("INFO", "Выход по запросу из трея")
    try Tunnel.Stop()
    catch {
    }
    try Tunnel._KillByPort()
    catch {
    }
    if State.MutexHwnd
        DllCall("CloseHandle", "Ptr", State.MutexHwnd)
    AppLog("INFO", "=== Скрипт завершён ===")
    ExitApp
}

; ============================================================
; Статус
; ============================================================
ShowStatus() {
    global Config, State, ConfigFile, LogFile

    cfgErr := Tunnel._ValidateConfig()
    portOk := IsPortListening(Config.LocalPort)
    pid := Tunnel._ReadPid()
    pidAlive := (pid != 0 && IsProcessAlive(pid))

    msg := "Сервер:           " Config.TargetUser "@" Config.TargetHost ":" Config.TargetPort "`n"
    msg .= "Локальный SOCKS5: 127.0.0.1:" Config.LocalPort "`n"
    msg .= "Порт слушается:   " (portOk ? "Да" : "Нет") "`n"
    msg .= "Режим входа:      "
        . (Config.AuthMode = "key" ? "SSH-ключ (ssh.exe)" : "Пароль (plink.exe)") "`n"
    msg .= "Managed PID:      " (pid != 0 ? pid : "нет") "`n"
    msg .= "PID активен:      " (pidAlive ? "Да" : "Нет") "`n"

    if (Config.AuthMode = "key") {
        msg .= "Файл ключа:       "
            . (Config.SshKey != ""
                ? (FileExist(Config.SshKey) ? Config.SshKey : "НЕ НАЙДЕН")
                    : "(не задан, используется агент)") "`n"
    } else {
        msg .= "plink.exe:        "
            . (FileExist(Config.PlinkExe) ? Config.PlinkExe : "НЕ НАЙДЕН") "`n"
        msg .= "Пароль:           "
            . (Config.Password != "" ? "задан" : "не задан") "`n"
    }

    if (cfgErr != "")
        msg .= "Конфигурация:     " cfgErr "`n"

    msg .= "`nПопыток перезапуска: " State.RetryCount "/" Config.MaxRetry "`n"
    msg .= "Статус: "
        . (State.GaveUp ? "ОСТАНОВЛЕН (лимит исчерпан)" : "Мониторинг активен") "`n"
    msg .= "`nКонфиг: " ConfigFile "`n"
    msg .= "Лог:    " LogFile

    MsgBox(msg, "Статус SSH Tunnel", "Iconi")
}

; ============================================================
; Автозапуск
; ============================================================
TrayToggleStartup(*) {
    shortcutPath := A_Startup "\" RegExReplace(A_ScriptName, "\.\w+$", ".lnk")

    if FileExist(shortcutPath) {
        try FileDelete(shortcutPath)
        AppLog("INFO", "Ярлык автозапуска удалён: " shortcutPath)
    } else {
        try {
            FileCreateShortcut(A_ScriptFullPath, shortcutPath, A_ScriptDir)
            AppLog("INFO", "Ярлык автозапуска создан: " shortcutPath)
        } catch as e {
            MsgBox("Не удалось создать ярлык:`n" e.Message, "Ошибка", "Icon!")
            return
        }
    }

    UpdateStartupMenuState()
}

UpdateStartupMenuState() {
    shortcutPath := A_Startup "\" RegExReplace(A_ScriptName, "\.\w+$", ".lnk")
    if FileExist(shortcutPath)
        A_TrayMenu.Check("Запускать при входе в систему")
    else
        A_TrayMenu.Uncheck("Запускать при входе в систему")
}
