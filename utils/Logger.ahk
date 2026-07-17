#Requires AutoHotkey v2.0

; ============================================================
; Логирование с уровнями: DEBUG / INFO / WARN / ERROR
;
; Использование:
;   AppLog("INFO",  "Туннель запущен")
;   AppLog("WARN",  "Порт не слушает")
;   AppLog("ERROR", "Не удалось запустить процесс")
;   AppLog("DEBUG", "PID = " pid)
;
; Минимальный уровень задаётся через Logger.MinLevel:
;   Logger.MinLevel := "DEBUG"   ; выводить всё
;   Logger.MinLevel := "INFO"    ; скрыть DEBUG
;   Logger.MinLevel := "WARN"    ; только WARN и ERROR
; ============================================================

class Logger {

    ; --- Настройки (можно менять до первого вызова AppLog) ---
    static MinLevel := "DEBUG"   ; минимальный уровень вывода
    static File := ""        ; путь к файлу (задаётся из основного скрипта)
    static MaxSize := 1048576   ; 1 МБ
    static MaxBackups := 5

    ; --- Числовые веса уровней для фильтрации ---
    static _Weights := Map("DEBUG", 0, "INFO", 1, "WARN", 2, "ERROR", 3)

    ; --- Интервал проверки ротации (мс) ---
    static _RotateInterval := 60000
    static _LastRotateCheck := 0

    ; --- Основной метод ---
    static Write(level, msg) {
        ; Фильтр по уровню
        minW := Logger._Weights.Has(Logger.MinLevel) ? Logger._Weights[Logger.MinLevel] : 0
        curW := Logger._Weights.Has(level) ? Logger._Weights[level] : 0
        if (curW < minW)
            return

        ; Ротация раз в минуту
        now := A_TickCount
        if (now - Logger._LastRotateCheck > Logger._RotateInterval) {
            Logger._LastRotateCheck := now
            try Logger._Rotate()
        }

        ts := FormatTime(, "yyyy-MM-dd HH:mm:ss")
        line := "[" ts "] [" level "] " msg "`r`n"

        try FileAppend(line, Logger.File, "UTF-8")
    }

    ; --- Ротация файла ---
    static _Rotate() {
        if !FileExist(Logger.File)
            return
        if (FileGetSize(Logger.File) < Logger.MaxSize)
            return

        ; Удалить самый старый бэкап
        oldest := Logger.File "." Logger.MaxBackups
        if FileExist(oldest)
            try FileDelete(oldest)

        ; Сдвинуть: .4 → .5, .3 → .4, ..., .1 → .2
        loop Logger.MaxBackups - 1 {
            i := Logger.MaxBackups - A_Index
            src := Logger.File "." i
            dst := Logger.File "." (i + 1)
            if FileExist(src)
                try FileMove(src, dst, 1)
        }

        ; Текущий → .1
        try FileMove(Logger.File, Logger.File ".1", 1)
    }
}

; --- Глобальная функция-обёртка для удобного вызова ---
; AppLog("INFO", "сообщение")
AppLog(level, msg) {
    Logger.Write(level, msg)
}
