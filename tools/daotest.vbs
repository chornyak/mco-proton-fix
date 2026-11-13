' Opens the game's Online.mdb through DAO 3.5 and writes the result to a file.
' Usage (inside the prefix): cscript //nologo daotest.vbs <path-to-Online.mdb> <output-file>
On Error Resume Next
Set fso = CreateObject("Scripting.FileSystemObject")
Set out = fso.CreateTextFile(WScript.Arguments(1), True)
Set e = CreateObject("DAO.DBEngine.35")
If Err.Number <> 0 Then
    out.WriteLine "FAIL create DBEngine: " & Err.Number & " " & Err.Description
    WScript.Quit 1
End If
Set db = e.OpenDatabase(WScript.Arguments(0), False, True)
If Err.Number <> 0 Then
    out.WriteLine "FAIL open database: " & Err.Number & " " & Err.Description
    WScript.Quit 1
End If
out.WriteLine "OK DAO " & e.Version & ", " & db.TableDefs.Count & " tables"
db.Close
out.Close
