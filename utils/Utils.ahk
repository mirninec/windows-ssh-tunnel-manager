#Requires AutoHotkey v2.0

; ============================================================
; Утилиты общего назначения
; Подключается через #Include Utils.ahk
; ============================================================

; --- Mutex: защита от повторного запуска ---
CreateMutexSingleInstance(name) {
    hMutex := DllCall("CreateMutexW", "Ptr", 0, "Int", 0, "Str", name, "Ptr")
    if !hMutex
        return 0
    lastErr := DllCall("GetLastError")
    if (lastErr = 183) {
        DllCall("CloseHandle", "Ptr", hMutex)
        return 0
    }
    return hMutex
}

; --- PowerShell: экранирование кавычек ---
EscapeForPowerShell(s) {
    return StrReplace(s, '"', '\"')
}

; --- PowerShell: запустить команду и дождаться завершения ---
; Возвращает код выхода (0 = успех) или -1 при ошибке запуска.
RunPsAndWait(psCommand) {
    psExe := A_WinDir "\System32\WindowsPowerShell\v1.0\powershell.exe"

    fullCmd := Format(
        '"{1}" -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "{2}"',
        psExe,
        EscapeForPowerShell(psCommand)
    )

    exitCode := 0
    try {
        exitCode := RunWait(fullCmd, , "Hide")
    } catch as e {
        AppLog("ERROR", "RunPsAndWait: " e.Message)
        return -1
    }
    return exitCode
}

; --- Проверка: слушает ли порт ---
IsPortListening(port) {
    ps := Format(
        "$c = Get-NetTCPConnection -State Listen -LocalPort {1} -ErrorAction SilentlyContinue;"
        "if ($c) {{ exit 0 }} else {{ exit 1 }}",
        port
    )
    return (RunPsAndWait(ps) = 0)
}

; --- Проверка: жив ли процесс по PID ---
IsProcessAlive(pid) {
    try {
        return !!ProcessExist(pid)
    } catch {
        return false
    }
}

; --- Валидация порта: целое число 1–65535 ---
IsValidPort(value) {
    v := Trim(String(value))
    if !RegExMatch(v, "^\d+$")
        return false
    n := Integer(v)
    return (n >= 1 && n <= 65535)
}

; --- Динамическая иконка трея: цветной кружок ---
SetTrayColorIcon(rgb) {
    static prevIcon := 0

    hIcon := CreateCircleIcon(rgb)
    if hIcon {
        TraySetIcon("HICON:*" hIcon)
        if prevIcon
            DllCall("DestroyIcon", "Ptr", prevIcon)
        prevIcon := hIcon
    }
}

CreateCircleIcon(rgb, size := 32) {
    static gdipToken := 0

    argb := 0xFF000000 | rgb

    if !gdipToken {
        if !DllCall("LoadLibrary", "Str", "gdiplus", "Ptr")
            return 0
        si := Buffer(24, 0)
        NumPut("UInt", 1, si, 0)
        if DllCall("gdiplus\GdiplusStartup", "Ptr*", &token := 0, "Ptr", si, "Ptr", 0)
            return 0
        gdipToken := token
    }

    if DllCall("gdiplus\GdipCreateBitmapFromScan0",
        "Int", size, "Int", size, "Int", 0,
        "Int", 0x26200A, "Ptr", 0, "Ptr*", &pBitmap := 0)
        return 0

    DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", pBitmap, "Ptr*", &pGraphics := 0)
    DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", pGraphics, "Int", 4)
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", argb, "Ptr*", &pBrush := 0)

    margin := 2
    d := size - margin * 2
    DllCall("gdiplus\GdipFillEllipse", "Ptr", pGraphics, "Ptr", pBrush,
        "Float", margin, "Float", margin, "Float", d, "Float", d)

    DllCall("gdiplus\GdipCreatePen1", "UInt", 0x80000000, "Float", 1.5, "Int", 2, "Ptr*", &pPen := 0)
    DllCall("gdiplus\GdipDrawEllipse", "Ptr", pGraphics, "Ptr", pPen,
        "Float", margin, "Float", margin, "Float", d, "Float", d)

    hIcon := 0
    DllCall("gdiplus\GdipCreateHICONFromBitmap", "Ptr", pBitmap, "Ptr*", &hIcon)

    DllCall("gdiplus\GdipDeletePen", "Ptr", pPen)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", pBrush)
    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", pGraphics)
    DllCall("gdiplus\GdipDisposeImage", "Ptr", pBitmap)

    return hIcon
}
