#Requires AutoHotkey v2.0

; ============================================================
; Класс Tunnel
;
; Инкапсулирует всю логику управления SSH-туннелем:
;   - построение команды (ssh.exe или plink.exe)
;   - запуск / остановка / перезапуск процесса
;   - проверка здоровья (PID + порт)
;   - счётчик попыток и флаг «сдались»
;
; Зависимости (должны быть подключены до этого файла):
;   #Include Utils.ahk
;   #Include Logger.ahk
;
; Использование:
;   Tunnel.Ensure()
;   Tunnel.Restart()
;   Tunnel.Stop()
; ============================================================

class Tunnel {

    ; --- Ссылки на общие объекты (задаются из основного скрипта) ---
    static Config := ""   ; объект Config (см. основной скрипт)
    static State := ""   ; объект State

    ; --- Публичный метод: убедиться, что туннель жив ---
    ; showBalloon — показывать ли всплывающее уведомление
    static Ensure(showBalloon := false) {
        if Tunnel.State.GaveUp {
            AppLog("DEBUG", "Tunnel.Ensure: GaveUp = true, пропускаем")
            return
        }

        AppLog("INFO", "Tunnel.Ensure: проверка состояния туннеля")

        err := Tunnel._ValidateConfig()
        if (err != "") {
            AppLog("ERROR", "Tunnel.Ensure: ошибка конфигурации — " err)
            Tunnel._SetTrayState("red")
            if showBalloon
                TrayTip(err, "SSH Tunnel", "3")
            return
        }

        pidAlive := Tunnel.IsAlive()
        portOk := IsPortListening(Tunnel.Config.LocalPort)

        AppLog("DEBUG", "Tunnel.Ensure: PID жив = " (pidAlive ? "да" : "нет")
        . ", порт слушает = " (portOk ? "да" : "нет"))

        if (!pidAlive || !portOk) {
            AppLog("WARN", "Tunnel.Ensure: туннель не здоров, перезапускаем")
            Tunnel._SetTrayState("yellow")
            Tunnel.Restart(false)
            if showBalloon
                TrayTip("Туннель был восстановлен", "SSH Tunnel", "1")
            return
        }

        AppLog("INFO", "Tunnel.Ensure: туннель работает нормально")
        Tunnel.State.RetryCount := 0
        Tunnel._SetTrayState("green")
        if showBalloon
            TrayTip("Туннель активен", "SSH Tunnel", "1")
    }

    ; --- Публичный метод: перезапустить туннель ---
    static Restart(showBalloon := false) {
        if Tunnel.State.GaveUp {
            AppLog("WARN", "Tunnel.Restart: уже сдались, пропускаем")
            return
        }

        Tunnel.State.RetryCount += 1
        AppLog("INFO", "Tunnel.Restart: попытка "
            . Tunnel.State.RetryCount "/" Tunnel.Config.MaxRetry)

        if (Tunnel.State.RetryCount > Tunnel.Config.MaxRetry) {
            Tunnel.State.GaveUp := true
            Tunnel._SetTrayState("red")
            AppLog("ERROR", "Tunnel.Restart: превышен лимит попыток ("
                . Tunnel.Config.MaxRetry ")")
            TrayTip(
                "Туннель не удалось поднять за " Tunnel.Config.MaxRetry " попыток.`n"
                . "Проверьте настройки. Для сброса — «Проверить / восстановить» в трее.",
                "SSH Tunnel — ошибка",
                "3 Mute"
            )
            return
        }

        Tunnel._SetTrayState("yellow")

        err := Tunnel._ValidateConfig()
        if (err != "") {
            AppLog("ERROR", "Tunnel.Restart: ошибка конфигурации — " err)
            Tunnel._SetTrayState("red")
            if showBalloon
                TrayTip(err, "SSH Tunnel", "3")
            return
        }

        Tunnel.Stop()
        Sleep(1000)

        ; Если порт всё ещё занят — принудительно убиваем
        if IsPortListening(Tunnel.Config.LocalPort) {
            AppLog("WARN", "Tunnel.Restart: порт всё ещё занят, принудительная остановка")
            Tunnel._KillByPort()
            Sleep(1000)
        }

        started := Tunnel.Start()
        AppLog("INFO", "Tunnel.Start вернул: " (started ? "true" : "false"))

        if started
            Sleep(Tunnel.Config.StartupWaitMs)

        pidAlive := Tunnel.IsAlive()
        portOk := IsPortListening(Tunnel.Config.LocalPort)

        if (!started || !pidAlive || !portOk) {
            Tunnel._SetTrayState("red")
        } else {
            Tunnel._SetTrayState("green")
            Tunnel.State.RetryCount := 0
        }

        if showBalloon {
            if !started {
                TrayTip("Не удалось запустить туннельный процесс", "SSH Tunnel", "3")
                return
            }
            if (pidAlive && portOk)
                TrayTip("Туннель перезапущен (попытка " Tunnel.State.RetryCount ")",
                    "SSH Tunnel", "1")
            else
                TrayTip("Не удалось поднять туннель. Проверь логин/ключ/пароль.",
                    "SSH Tunnel", "2")
        }
    }

    ; --- Публичный метод: запустить процесс туннеля ---
    ; Возвращает true при успехе.
    static Start() {
        cmd := Tunnel._BuildCommand()
        if (cmd = "")
            return false
        return Tunnel._RunProcess(cmd)
    }

    ; --- Публичный метод: остановить управляемый процесс ---
    static Stop() {
        pid := Tunnel._ReadPid()
        if (pid = 0) {
            AppLog("DEBUG", "Tunnel.Stop: управляемый PID не найден")
            return
        }
        AppLog("INFO", "Tunnel.Stop: останавливаем PID " pid)
        if IsProcessAlive(pid) {
            try {
                ProcessClose(pid)
                AppLog("INFO", "Tunnel.Stop: PID " pid " закрыт")
            } catch as e {
                AppLog("ERROR", "Tunnel.Stop: ProcessClose для PID " pid " — " e.Message)
            }
        } else {
            AppLog("DEBUG", "Tunnel.Stop: PID " pid " уже не активен")
        }
        Tunnel._DeletePid()
    }

    ; --- Публичный метод: проверить, жив ли управляемый процесс ---
    static IsAlive() {
        pid := Tunnel._ReadPid()
        if (pid = 0)
            return false
        return IsProcessAlive(pid)
    }

    ; ============================================================
    ; Приватные методы
    ; ============================================================

    ; --- Построить команду запуска туннеля ---
    static _BuildCommand() {
        cfg := Tunnel.Config
        if (cfg.AuthMode = "key")
            return Tunnel._BuildSshCommand()
        else
            return Tunnel._BuildPlinkCommand()
    }

    ; --- Команда для OpenSSH ---
    static _BuildSshCommand() {
        cfg := Tunnel.Config

        commonOpts := "-C -T -N -D " cfg.LocalPort
            . " -o ServerAliveInterval=30"
            . " -o ServerAliveCountMax=3"
            . " -o ExitOnForwardFailure=yes"
            . " -o StrictHostKeyChecking=accept-new"
            . " -o BatchMode=yes"

        sshExe := A_WinDir "\System32\OpenSSH\ssh.exe"

        if (cfg.SshKey != "") {
            cmd := Format('"{1}" -i "{2}" -p {3} {4} {5}@{6}',
                sshExe, cfg.SshKey, cfg.TargetPort,
                commonOpts, cfg.TargetUser, cfg.TargetHost)
        } else {
            cmd := Format('"{1}" -p {2} {3} {4}@{5}',
                sshExe, cfg.TargetPort,
                commonOpts, cfg.TargetUser, cfg.TargetHost)
        }

        AppLog("INFO", "SSH команда: " cmd)
        return cmd
    }

    ; --- Команда для plink.exe ---
    static _BuildPlinkCommand() {
        cfg := Tunnel.Config

        cmd := Format(
            '"{1}" -ssh -batch -N -D {2} -P {3} -l "{4}" -pw "{5}" {6}',
            cfg.PlinkExe, cfg.LocalPort, cfg.TargetPort,
            cfg.TargetUser, cfg.Password, cfg.TargetHost
        )

        ; В лог пишем с маскированным паролем
        cmdLog := Format(
            '"{1}" -ssh -batch -N -D {2} -P {3} -l "{4}" -pw "***" {5}',
            cfg.PlinkExe, cfg.LocalPort, cfg.TargetPort,
            cfg.TargetUser, cfg.TargetHost
        )
        AppLog("INFO", "Plink команда: " cmdLog)

        return cmd
    }

    ; --- Запустить процесс и сохранить PID ---
    static _RunProcess(cmd) {
        pid := 0
        try {
            Run(cmd, , "Hide", &pid)
            Tunnel._SavePid(pid)
            AppLog("INFO", "Tunnel._RunProcess: процесс запущен, PID = " pid)
            return true
        } catch as e {
            AppLog("ERROR", "Tunnel._RunProcess: Run() не удался — " e.Message)
            return false
        }
    }

    ; --- Принудительно убить процессы туннеля по номеру порта ---
    static _KillByPort() {
        cfg := Tunnel.Config
        procName := (cfg.AuthMode = "password") ? "plink.exe" : "ssh.exe"
        port := cfg.LocalPort

        AppLog("WARN", "Tunnel._KillByPort: убиваем " procName " по -D " port)

        ps := (
            "$procs = Get-CimInstance Win32_Process | Where-Object { "
            "$_.Name -eq '" procName "' -and $_.CommandLine -match '(^|\s)-D\s*" port "(\s|$)' "
            "}; "
            "foreach ($p in $procs) { "
            "try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop } catch {} "
            "}"
        )
        RunPsAndWait(ps)
    }

    ; --- Валидация конфигурации ---
    ; Возвращает строку с ошибкой или "" если всё в порядке.
    static _ValidateConfig() {
        cfg := Tunnel.Config
        psExe := A_WinDir "\System32\WindowsPowerShell\v1.0\powershell.exe"
        sshExe := A_WinDir "\System32\OpenSSH\ssh.exe"

        if !FileExist(psExe)
            return "Не найден powershell.exe"
        if (cfg.TargetUser = "")
            return "Не задан пользователь SSH"
        if (cfg.TargetHost = "")
            return "Не задан хост SSH"
        if (cfg.LocalPort = 0)
            return "Не задан локальный порт"

        if (cfg.AuthMode = "key") {
            if !FileExist(sshExe)
                return "Не найден ssh.exe"
            if (cfg.SshKey != "" && !FileExist(cfg.SshKey))
                return "Не найден файл ключа: " cfg.SshKey
        } else {
            if !FileExist(cfg.PlinkExe)
                return "Не найден plink.exe: " cfg.PlinkExe
            if (cfg.Password = "")
                return "Не задан пароль для режима plink"
        }

        return ""
    }

    ; --- Установить визуальное состояние иконки трея ---
    static _SetTrayState(state) {
        if (Tunnel.State.TrayState = state)
            return
        Tunnel.State.TrayState := state

        if (state = "green") {
            A_IconTip := "SSH Tunnel: активен"
            SetTrayColorIcon(0x2ECC40)
        } else if (state = "yellow") {
            A_IconTip := "SSH Tunnel: проверка / перезапуск"
            SetTrayColorIcon(0xFFD000)
        } else {
            A_IconTip := "SSH Tunnel: не работает"
            SetTrayColorIcon(0xFF4136)
        }
    }

    ; --- PID-файл: сохранить ---
    static _SavePid(pid) {
        pidFile := Tunnel.State.PidFile
        try FileDelete(pidFile)
        try FileAppend(String(pid), pidFile, "UTF-8")
    }

    ; --- PID-файл: прочитать ---
    static _ReadPid() {
        pidFile := Tunnel.State.PidFile
        try {
            if !FileExist(pidFile)
                return 0
            txt := Trim(FileRead(pidFile, "UTF-8"))
            if RegExMatch(txt, "^\d+$")
                return Integer(txt)
        } catch {
        }
        return 0
    }

    ; --- PID-файл: удалить ---
    static _DeletePid() {
        try FileDelete(Tunnel.State.PidFile)
    }
}
