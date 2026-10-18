Option Explicit

Dim shell, fso, scriptDir, root, cachePath, runner, fallback, command, exitCode
Dim stream, bundle, executable, node

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
root = fso.GetParentFolderName(scriptDir)
cachePath = fso.BuildPath(root, "launcher-cache.txt")
runner = fso.BuildPath(root, "extension\run-windows.mjs")
fallback = fso.BuildPath(scriptDir, "launch-windows.ps1")

Function Quote(value)
  Quote = Chr(34) & Replace(value, Chr(34), Chr(34) & Chr(34)) & Chr(34)
End Function

If fso.FileExists(cachePath) Then
  Set stream = fso.OpenTextFile(cachePath, 1, False)
  If Not stream.AtEndOfStream Then bundle = stream.ReadLine
  If Not stream.AtEndOfStream Then executable = stream.ReadLine
  If Not stream.AtEndOfStream Then node = stream.ReadLine
  stream.Close

  If fso.FolderExists(bundle) And fso.FileExists(executable) And fso.FileExists(node) And fso.FileExists(runner) Then
    command = Quote(node) & " " & Quote(runner) & " --bundle " & Quote(bundle) & " --executable " & Quote(executable)
    exitCode = shell.Run(command, 0, True)
    If exitCode = 0 Then WScript.Quit 0
  End If
End If

command = Quote(shell.ExpandEnvironmentStrings("%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe")) & _
  " -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Quote(fallback)
shell.Run command, 0, False
