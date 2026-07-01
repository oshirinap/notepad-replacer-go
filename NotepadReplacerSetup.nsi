!include "MUI2.nsh"
!include "nsDialogs.nsh"
; Note: we don't use nsJSON at all -- both reading and writing config.json
; are hand-rolled (see JsonExtractString / WriteConfigJson below). This
; avoids depending on plugin-specific array semantics we can't compile-test
; ourselves (see the "args": [] bug this replaced).

!define APP_NAME "Notepad Replacer"
!define OUT_FILE "NotepadReplacerSetup.exe"

Name "${APP_NAME}"
OutFile "${OUT_FILE}"
InstallDir "$PROFILE\.notepad-replacer"
RequestExecutionLevel admin

; --- UI Variables ---
Var Dialog
Var RadioExe
Var RadioVbs
Var InstallationType

Var DialogEditor
Var TextExePath
Var BrowseButton
Var TextArgs
Var EditorExePath
Var EditorArgs
Var ConfigPath

; --- Hand-rolled JSON reader plumbing (named vars, not numbered registers,
; so nested Calls between these helper functions can't clobber each other's
; parameters) ---
Var JsonText
Var SF_Haystack
Var SF_Needle
Var SF_Start
Var SF_Result
Var JE_Value
Var JA_Value

; --- Pages ---
!insertmacro MUI_PAGE_DIRECTORY
Page custom CreateEditorPage LeaveEditorPage
Page custom CreateOptionsPage LeaveOptionsPage
!insertmacro MUI_PAGE_INSTFILES

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

; --- Languages ---
!insertmacro MUI_LANGUAGE "English"

; --- Initialization Check ---
Function .onInit
    StrCpy $ConfigPath "$PROFILE\.notepad-replacer\config.json"

    ; Check both the native 64-bit view and the Wow6432Node (32-bit) view,
    ; but surface a single combined prompt -- the distinction isn't
    ; meaningful to the average user, and we always act on both together.
    StrCpy $0 ""

    SetRegView 64
    ClearErrors
    ReadRegStr $1 HKLM "SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\notepad.exe" "Debugger"
    IfErrors +2
        StrCpy $0 "1"

    SetRegView 32
    ClearErrors
    ReadRegStr $1 HKLM "SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\notepad.exe" "Debugger"
    IfErrors +2
        StrCpy $0 "1"

    StrCmp $0 "1" 0 proceed
        MessageBox MB_YESNO "Notepad replacement registry key already exists. Do you want to remove it? (Choose No to reconfigure the existing installation instead.)" IDYES run_uninstaller IDNO proceed

run_uninstaller:
    IfFileExists "$INSTDIR\uninstall.exe" 0 remove_reg_directly
        ExecWait '"$INSTDIR\uninstall.exe" /S'
        Quit

remove_reg_directly:
    SetRegView 64
    DeleteRegValue HKLM "SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\notepad.exe" "Debugger"
    SetRegView 32
    DeleteRegValue HKLM "SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\notepad.exe" "Debugger"
    MessageBox MB_OK "Existing registry keys have been removed."
    Quit

proceed:
FunctionEnd

; --- Editor Configuration Page ---
; Asks for the target editor's exe path + optional default arguments.
; Pre-fills from an existing config.json (if any), so re-running the
; installer to reconfigure doesn't start from a blank form.
Function CreateEditorPage
    nsDialogs::Create 1018
    Pop $DialogEditor

    StrCmp $DialogEditor "error" 0 +2
        Abort

    StrCpy $EditorExePath ""
    StrCpy $EditorArgs ""
    Call ReadConfigForPrefill

    ${NSD_CreateLabel} 0 0 100% 12u "Path to the editor you want notepad.exe to open instead:"
    Pop $0

    ${NSD_CreateText} 0 14u 78% 12u "$EditorExePath"
    Pop $TextExePath

    ${NSD_CreateBrowseButton} 80% 14u 20% 12u "Browse..."
    Pop $BrowseButton
    ${NSD_OnClick} $BrowseButton OnBrowseEditor

    ${NSD_CreateLabel} 0 32u 100% 12u "Extra arguments to pass to the editor (optional, space-separated):"
    Pop $0

    ${NSD_CreateText} 0 46u 100% 12u "$EditorArgs"
    Pop $TextArgs

    nsDialogs::Show
FunctionEnd

; ============================================================
; Hand-rolled config.json reader (mirrors invis.vbs's approach --
; no plugin dependency, fully under our control).
; ============================================================

; Reads $ConfigPath into $JsonText, then extracts "exe" -> $EditorExePath
; and "args" (joined with spaces) -> $EditorArgs. Leaves both blank if the
; file doesn't exist or the keys aren't found.
Function ReadConfigForPrefill
    Push $8  ; file handle
    Push $0  ; line buffer

    StrCpy $JsonText ""
    ClearErrors
    FileOpen $8 "$ConfigPath" r
    IfErrors rcp_done

rcp_read_loop:
    ClearErrors
    FileRead $8 $0
    IfErrors rcp_close
    StrCpy $JsonText "$JsonText$0"
    Goto rcp_read_loop

rcp_close:
    FileClose $8

    StrCpy $JE_Value "exe"
    Call JsonExtractString
    StrCpy $EditorExePath $JE_Value

    Call JsonExtractArgsJoined
    StrCpy $EditorArgs $JA_Value

rcp_done:
    Pop $0
    Pop $8
FunctionEnd

; Linear substring search.
; In:  $SF_Haystack, $SF_Needle, $SF_Start (0-based)
; Out: $SF_Result = index of first match at/after start, or -1
Function StrFindFrom
    Push $R0  ; haylen
    Push $R1  ; needlen
    Push $R2  ; i
    Push $R3  ; sub

    StrLen $R0 $SF_Haystack
    StrLen $R1 $SF_Needle
    StrCpy $R2 $SF_Start

sff_loop:
    IntCmp $R2 $R0 sff_try sff_try sff_notfound
sff_try:
    StrCpy $R3 $SF_Haystack $R1 $R2
    StrCmp $R3 $SF_Needle sff_found
    IntOp $R2 $R2 + 1
    Goto sff_loop
sff_found:
    StrCpy $SF_Result $R2
    Goto sff_end
sff_notfound:
    StrCpy $SF_Result -1
sff_end:
    Pop $R3
    Pop $R2
    Pop $R1
    Pop $R0
FunctionEnd

; JSON unescaping (\\ -> \, \" -> "). In/Out: $JE_Value
Function UnescapeJsonString
    Push $R0  ; result
    Push $R1  ; remaining
    Push $R2  ; char
    Push $R3  ; next char

    StrCpy $R0 ""
    StrCpy $R1 $JE_Value

uj_loop:
    StrCmp $R1 "" uj_done
    StrCpy $R2 $R1 1
    StrCmp $R2 "\" uj_esc
    StrCpy $R0 "$R0$R2"
    StrCpy $R1 $R1 "" 1
    Goto uj_loop
uj_esc:
    StrCpy $R3 $R1 1 1
    StrCmp $R3 "\" uj_esc_bs
    StrCmp $R3 '"' uj_esc_qt
    StrCpy $R0 "$R0\"
    StrCpy $R1 $R1 "" 1
    Goto uj_loop
uj_esc_bs:
    StrCpy $R0 '$R0\'
    StrCpy $R1 $R1 "" 2
    Goto uj_loop
uj_esc_qt:
    StrCpy $R0 '$R0"'
    StrCpy $R1 $R1 "" 2
    Goto uj_loop
uj_done:
    StrCpy $JE_Value $R0
    Pop $R3
    Pop $R2
    Pop $R1
    Pop $R0
FunctionEnd

; Extracts a top-level string value for a given key.
; In/Out: $JE_Value (key name in, extracted+unescaped value out, "" if absent)
; Reads from $JsonText.
Function JsonExtractString
    Push $R0  ; "key" with quotes
    Push $R1  ; keyPos
    Push $R2  ; colonPos
    Push $R3  ; q1 (after opening quote)
    Push $R4  ; q2 (closing quote)

    StrCpy $R0 '"$JE_Value"'

    StrCpy $SF_Haystack $JsonText
    StrCpy $SF_Needle $R0
    StrCpy $SF_Start 0
    Call StrFindFrom
    StrCpy $R1 $SF_Result
    StrCmp $R1 -1 je_notfound

    StrCpy $SF_Haystack $JsonText
    StrCpy $SF_Needle ":"
    StrCpy $SF_Start $R1
    Call StrFindFrom
    StrCpy $R2 $SF_Result
    StrCmp $R2 -1 je_notfound

    StrCpy $SF_Haystack $JsonText
    StrCpy $SF_Needle '"'
    StrCpy $SF_Start $R2
    Call StrFindFrom
    StrCpy $R3 $SF_Result
    StrCmp $R3 -1 je_notfound
    IntOp $R3 $R3 + 1

    StrCpy $SF_Haystack $JsonText
    StrCpy $SF_Needle '"'
    StrCpy $SF_Start $R3
    Call StrFindFrom
    StrCpy $R4 $SF_Result
    StrCmp $R4 -1 je_notfound

    IntOp $R2 $R4 - $R3
    StrCpy $JE_Value $JsonText $R2 $R3
    Call UnescapeJsonString
    Goto je_end

je_notfound:
    StrCpy $JE_Value ""

je_end:
    Pop $R4
    Pop $R3
    Pop $R2
    Pop $R1
    Pop $R0
FunctionEnd

; Extracts the "args" array and joins it into a single space-separated
; string (each token unescaped) for display in the args text field.
; Out: $JA_Value. Reads from $JsonText.
Function JsonExtractArgsJoined
    Push $R0  ; keyPos
    Push $R1  ; b1 (position of '[')
    Push $R2  ; b2 (position of ']')
    Push $R3  ; scan position
    Push $R4  ; q1
    Push $R5  ; q2
    Push $R6  ; "first token" flag
    Push $R7  ; token length

    StrCpy $JA_Value ""

    StrCpy $SF_Haystack $JsonText
    StrCpy $SF_Needle '"args"'
    StrCpy $SF_Start 0
    Call StrFindFrom
    StrCpy $R0 $SF_Result
    StrCmp $R0 -1 ja_done

    StrCpy $SF_Haystack $JsonText
    StrCpy $SF_Needle "["
    StrCpy $SF_Start $R0
    Call StrFindFrom
    StrCpy $R1 $SF_Result
    StrCmp $R1 -1 ja_done

    StrCpy $SF_Haystack $JsonText
    StrCpy $SF_Needle "]"
    StrCpy $SF_Start $R1
    Call StrFindFrom
    StrCpy $R2 $SF_Result
    StrCmp $R2 -1 ja_done

    StrCpy $R6 "1"
    StrCpy $R3 $R1

ja_loop:
    StrCpy $SF_Haystack $JsonText
    StrCpy $SF_Needle '"'
    StrCpy $SF_Start $R3
    Call StrFindFrom
    StrCpy $R4 $SF_Result
    StrCmp $R4 -1 ja_done
    IntCmp $R4 $R2 ja_done ja_next ja_done
ja_next:
    IntOp $R4 $R4 + 1

    StrCpy $SF_Haystack $JsonText
    StrCpy $SF_Needle '"'
    StrCpy $SF_Start $R4
    Call StrFindFrom
    StrCpy $R5 $SF_Result
    StrCmp $R5 -1 ja_done

    IntOp $R7 $R5 - $R4
    StrCpy $JE_Value $JsonText $R7 $R4
    Call UnescapeJsonString

    StrCmp $R6 "1" 0 ja_append_sep
        StrCpy $R6 "0"
        StrCpy $JA_Value "$JE_Value"
        Goto ja_advance
ja_append_sep:
    StrCpy $JA_Value "$JA_Value $JE_Value"
ja_advance:
    IntOp $R3 $R5 + 1
    Goto ja_loop

ja_done:
    Pop $R7
    Pop $R6
    Pop $R5
    Pop $R4
    Pop $R3
    Pop $R2
    Pop $R1
    Pop $R0
FunctionEnd

Function OnBrowseEditor
    nsDialogs::SelectFileDialog "open" "" "Executable files (*.exe)|*.exe|All files (*.*)|*.*"
    Pop $0
    StrCmp $0 "" done
        ${NSD_SetText} $TextExePath $0
done:
FunctionEnd

Function LeaveEditorPage
    ${NSD_GetText} $TextExePath $EditorExePath
    ${NSD_GetText} $TextArgs $EditorArgs

    StrCmp $EditorExePath "" 0 check_exists
        MessageBox MB_OK "Please choose the editor executable to use."
        Abort

check_exists:
    IfFileExists "$EditorExePath" done
        MessageBox MB_OK "That file doesn't seem to exist: $EditorExePath"
        Abort
done:
FunctionEnd

; --- Custom Options Page (EXE vs VBS shim) ---
Function CreateOptionsPage
    nsDialogs::Create 1018
    Pop $Dialog

    StrCmp $Dialog "error" 0 +2
        Abort

    ${NSD_CreateLabel} 0 0 100% 12u "Select which version of the replacer to register:"
    Pop $0

    ${NSD_CreateRadioButton} 10u 20u 90% 10u "Use standard executable (.exe version)"
    Pop $RadioExe
    ${NSD_Check} $RadioExe

    ; Height set to 24u to support clean two-line dialog wrapping without clipping text
    ${NSD_CreateRadioButton} 10u 35u 90% 24u "Use VBScript script (.vbs backup version - recommended if unsigned EXE is blocked)"
    Pop $RadioVbs

    nsDialogs::Show
FunctionEnd

Function LeaveOptionsPage
    ${NSD_GetState} $RadioExe $0
    StrCmp $0 ${BST_CHECKED} 0 +3
        StrCpy $InstallationType "EXE"
        Goto done
    StrCpy $InstallationType "VBS"

done:
FunctionEnd

; --- JSON string escaping (backslash + quote) ---
; In/Out: $9
Function EscapeJsonString
    Push $R0
    Push $R1
    Push $R2
    StrCpy $R0 ""
    StrCpy $R1 $9
ejs_loop:
    StrCmp $R1 "" ejs_done
    StrCpy $R2 $R1 1
    StrCmp $R2 "\" ejs_bs
    StrCmp $R2 '"' ejs_qt
    StrCpy $R0 "$R0$R2"
    Goto ejs_cont
ejs_bs:
    StrCpy $R0 '$R0\\'
    Goto ejs_cont
ejs_qt:
    StrCpy $R0 '$R0\"'
ejs_cont:
    StrCpy $R1 $R1 "" 1
    Goto ejs_loop
ejs_done:
    StrCpy $9 $R0
    Pop $R2
    Pop $R1
    Pop $R0
FunctionEnd

; --- Writes config.json by hand (no nsJSON dependency for the write side).
; Splits $EditorArgs on spaces and always emits a well-formed "args" array,
; empty ([]) if no args were given. Deterministic -- no plugin call whose
; exact array-creation semantics we can't verify by compiling ourselves. ---
Function WriteConfigJson
    Push $8   ; file handle
    Push $9   ; escape scratch (shared with EscapeJsonString)
    Push $R0  ; remaining args
    Push $R1  ; current word
    Push $R2  ; scan pos
    Push $R3  ; char
    Push $R4  ; "first arg written yet" flag

    FileOpen $8 "$ConfigPath" w
    IfErrors wcj_fail

    FileWrite $8 "{$\r$\n"

    StrCpy $9 $EditorExePath
    Call EscapeJsonString
    FileWrite $8 '  "exe": "$9",$\r$\n'

    FileWrite $8 '  "args": ['

    StrCpy $R0 $EditorArgs
    StrCpy $R4 "1"

    ; trim leading spaces
wcj_trim:
    StrCpy $R3 $R0 1
    StrCmp $R3 " " 0 wcj_loop
        StrCpy $R0 $R0 "" 1
        Goto wcj_trim

wcj_loop:
    StrCmp $R0 "" wcj_args_done
        StrCpy $R2 0
wcj_find_space:
        StrCpy $R3 $R0 1 $R2
        StrCmp $R3 "" wcj_got_word
        StrCmp $R3 " " wcj_got_word
        IntOp $R2 $R2 + 1
        Goto wcj_find_space
wcj_got_word:
        StrCpy $R1 $R0 $R2
        StrCpy $R0 $R0 "" $R2
wcj_trim2:
        StrCpy $R3 $R0 1
        StrCmp $R3 " " 0 wcj_write_word
            StrCpy $R0 $R0 "" 1
            Goto wcj_trim2
wcj_write_word:
        StrCmp $R1 "" wcj_loop
            StrCmp $R4 "1" 0 wcj_comma
                StrCpy $R4 "0"
                Goto wcj_no_comma
wcj_comma:
            FileWrite $8 ","
wcj_no_comma:
            StrCpy $9 $R1
            Call EscapeJsonString
            FileWrite $8 '"$9"'
            Goto wcj_loop

wcj_args_done:
    FileWrite $8 "]$\r$\n"
    FileWrite $8 "}$\r$\n"
    FileClose $8
    Goto wcj_done

wcj_fail:
    MessageBox MB_OK "Failed to write config.json to $ConfigPath"

wcj_done:
    Pop $R4
    Pop $R3
    Pop $R2
    Pop $R1
    Pop $R0
    Pop $9
    Pop $8
FunctionEnd

; --- Installation Section ---
Section "Install"
    SetOutPath $INSTDIR

    File "invis.exe"
    File "invis.vbs"

    WriteUninstaller "$INSTDIR\uninstall.exe"

    ; --- Write config.json (hand-rolled -- see WriteConfigJson) ---
    CreateDirectory "$PROFILE\.notepad-replacer"
    Call WriteConfigJson

    StrCmp $InstallationType "EXE" 0 install_vbs
        DetailPrint "Registering executable version..."
        SetRegView 64
        WriteRegStr HKLM "SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\notepad.exe" "Debugger" '"$INSTDIR\invis.exe" -3qlsvw92'
        SetRegView 32
        WriteRegStr HKLM "SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\notepad.exe" "Debugger" '"$INSTDIR\invis.exe" -3qlsvw92'
        Goto install_done

install_vbs:
        DetailPrint "Registering VBScript backup version..."
        SetRegView 64
        WriteRegStr HKLM "SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\notepad.exe" "Debugger" 'wscript.exe "$INSTDIR\invis.vbs" -3qlsvw92'
        SetRegView 32
        WriteRegStr HKLM "SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\notepad.exe" "Debugger" 'wscript.exe "$INSTDIR\invis.vbs" -3qlsvw92'

install_done:
    DetailPrint "Notepad replacement configured successfully."
SectionEnd

; --- Uninstallation Section ---
Section "Uninstall"
    SetRegView 64
    DeleteRegValue HKLM "SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\notepad.exe" "Debugger"

    SetRegView 32
    DeleteRegValue HKLM "SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\notepad.exe" "Debugger"

    Delete "$INSTDIR\uninstall.exe"
    Delete "$INSTDIR\invis.exe"
    Delete "$INSTDIR\invis.vbs"
    RMDir "$INSTDIR"

    DetailPrint "Notepad replacement keys and files removed successfully."
SectionEnd
