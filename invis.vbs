Option Explicit

' notepad-replacer VBS shim
' Self-contained: reads %USERPROFILE%\.notepad-replacer\config.json directly
' and launches the configured editor, fully hidden. Does NOT rely on a
' separate "shim" argument being passed before the marker.
'
' Registered as: wscript.exe "invis.vbs" -3qlsvw92
' (must be launched via wscript.exe/cscript.exe -- IFEO's Debugger value
' cannot execute a .vbs file directly, it needs a real interpreter exe.)

Const MARKER = "-3qlsvw92"

Dim args, num, WshShell, fso
Set WshShell = WScript.CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

Set args = WScript.Arguments
num = args.Count

' --- Locate the marker among our own argv ---
Dim markerIndex, i
markerIndex = -1
For i = 0 To num - 1
  If args.Item(i) = MARKER Then
    markerIndex = i
    Exit For
  End If
Next

' --- Collect the "real" args Windows forwarded (the file the user opened).
' notepad.exe only ever opens one file at a time. If the file association
' that triggered this didn't quote its %1 placeholder, a filename with
' spaces arrives here already split into separate tokens -- IFEO's
' Debugger mechanism prepends our shim in front of the original command
' line verbatim, it doesn't fix quoting. There's no reliable way to tell
' "genuinely separate files" from "one filename that lost its quotes"
' after the fact, so we always rejoin every trailing token into a single
' argument, matching notepad.exe's own single-file behavior. ---
Dim forwarded, startIndex, j, a, joinedFile
joinedFile = ""
If markerIndex >= 0 Then
  startIndex = markerIndex + 1
Else
  startIndex = 0
End If

For j = startIndex To num - 1
  a = args.Item(j)
  If a = MARKER Then
    ' skip
  ElseIf j = startIndex And IsExePath(a) Then
    ' Windows re-injects the original notepad.exe path as the first
    ' forwarded token -- skip it, we don't want to pass it to the editor.
  Else
    If joinedFile = "" Then
      joinedFile = a
    Else
      joinedFile = joinedFile & " " & a
    End If
  End If
Next

If joinedFile <> "" Then
  forwarded = " " & Chr(34) & joinedFile & Chr(34)
Else
  forwarded = ""
End If

' --- Read config.json for the target editor exe + default args ---
Dim configPath, jsonText, ts, exePath, configArgs
configPath = WshShell.ExpandEnvironmentStrings("%USERPROFILE%") & "\.notepad-replacer\config.json"

If Not fso.FileExists(configPath) Then
  WScript.Echo "notepad-replacer: config file not found at " & configPath
  WScript.Quit 1
End If

Set ts = fso.OpenTextFile(configPath, 1)
jsonText = ts.ReadAll()
ts.Close

exePath = ExtractJsonString(jsonText, "exe")
If exePath = "" Then
  WScript.Echo "notepad-replacer: 'exe' missing from config.json"
  WScript.Quit 1
End If

configArgs = ExtractJsonStringArray(jsonText, "args")

' --- Launch the editor, fully hidden (0 = hidden window, False = don't wait) ---
Dim cmd
cmd = Chr(34) & exePath & Chr(34) & configArgs & forwarded
WshShell.Run cmd, 0, False

' ============================================================
' Helpers
' ============================================================

Function IsExePath(s)
  IsExePath = (InStrRev(LCase(s), ".exe") = Len(s) - 3)
End Function

' Minimal hand-rolled JSON reader. Only handles the flat shape
' notepad-replacer writes: { "exe": "...", "args": ["...", "..."] }
' This is NOT a general JSON parser.

Function ExtractJsonString(json, key)
  Dim needle, p, q1, q2, raw
  needle = Chr(34) & key & Chr(34)
  ExtractJsonString = ""
  p = InStr(json, needle)
  If p = 0 Then Exit Function
  p = InStr(p, json, ":")
  If p = 0 Then Exit Function
  q1 = InStr(p, json, Chr(34))
  If q1 = 0 Then Exit Function
  q2 = FindUnescapedQuote(json, q1 + 1)
  If q2 = 0 Then Exit Function
  raw = Mid(json, q1 + 1, q2 - q1 - 1)
  ExtractJsonString = UnescapeJson(raw)
End Function

Function ExtractJsonStringArray(json, key)
  Dim needle, p, b1, b2, body, pos, q1, q2, item, result
  needle = Chr(34) & key & Chr(34)
  ExtractJsonStringArray = ""
  p = InStr(json, needle)
  If p = 0 Then Exit Function
  b1 = InStr(p, json, "[")
  b2 = InStr(p, json, "]")
  If b1 = 0 Or b2 = 0 Or b2 < b1 Then Exit Function
  body = Mid(json, b1 + 1, b2 - b1 - 1)

  result = ""
  pos = 1
  Do
    q1 = InStr(pos, body, Chr(34))
    If q1 = 0 Then Exit Do
    q2 = FindUnescapedQuote(body, q1 + 1)
    If q2 = 0 Then Exit Do
    item = Mid(body, q1 + 1, q2 - q1 - 1)
    result = result & " " & Chr(34) & UnescapeJson(item) & Chr(34)
    pos = q2 + 1
  Loop

  ExtractJsonStringArray = result
End Function

' Finds the next quote in s starting at index `start` that isn't escaped
' (i.e. not preceded by an odd number of backslashes).
Function FindUnescapedQuote(s, start)
  Dim p, bs, k
  p = start
  Do
    p = InStr(p, s, Chr(34))
    If p = 0 Then
      FindUnescapedQuote = 0
      Exit Function
    End If
    bs = 0
    k = p - 1
    Do While k >= 1 And Mid(s, k, 1) = "\"
      bs = bs + 1
      k = k - 1
    Loop
    If bs Mod 2 = 0 Then
      FindUnescapedQuote = p
      Exit Function
    End If
    p = p + 1
  Loop
End Function

Function UnescapeJson(s)
  s = Replace(s, "\\", "\")
  s = Replace(s, "\" & Chr(34), Chr(34))
  UnescapeJson = s
End Function
