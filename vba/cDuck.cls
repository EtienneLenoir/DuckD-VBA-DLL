VERSION 1.0 CLASS
BEGIN
  MultiUse = -1  'True
END
Attribute VB_Name = "cDuck"
Attribute VB_GlobalNameSpace = False
Attribute VB_Creatable = False
Attribute VB_PredeclaredId = False
Attribute VB_Exposed = False
' ========= Classe : cDuck =========
Option Explicit

'==============================================================================
' DUCK VBA DLL — DuckDB bridge for Excel/VBA
' Copyright (c) 2026 Etienne Lenoir
' SPDX-License-Identifier: GPL-3.0-only
' License  : GNU General Public License v3.0 (see LICENSE at repository root)
' Requires Excel 64-bit (VBA7) + duckdb.dll + duckdb_vba_bridge.dll
'==============================================================================

'Modes de gestion d'erreur
Private Enum DuckErrorMode
    demRaise = 0      'comme aujourd'hui : Err.Raise
    demMsgBox = 1     'MsgBox uniquement
    demLogOnly = 2    'écrit dans un log, pas de MsgBox, pas de Err.Raise
End Enum
Private m_ErrorMode     As DuckErrorMode
Private m_LastError     As String
Private m_LogFilePath   As String
Private m_h             As LongPtr
Private m_inTx          As Boolean
Private m_basePath      As String

'-- Init / OpenDuckDb / CloseDuckDb -----------------------------------------
Public Sub Init(Optional ByVal dllFolder As String = "")
    If dllFolder = "" Then dllFolder = ThisWorkbook.Path
    m_basePath = dllFolder
    m_inTx = False
    Call EnsureDuckDll(m_basePath)
    
    m_ErrorMode = demLogOnly     'demRaise  ou demMsgBox, ou demLogOnly selon tes goûts
    m_LastError = ""
End Sub

Private Sub Class_Terminate()
    On Error Resume Next
    If m_inTx Then Me.Rollback
    If m_h <> 0 Then DuckVba_Close m_h
    m_h = 0
    m_inTx = False
End Sub

'Retourne True si OK, sinon HandleError et False
Private Function CheckOk(ByVal ok As Long, ByVal userMsg As String, Optional ByVal details As String = vbNullString) As Boolean
    If ok = 0 Then
        If Len(details) > 0 Then
            HandleError userMsg & vbCrLf & details
        Else
            HandleError userMsg
        End If
        CheckOk = False
    Else
        m_LastError = vbNullString
        CheckOk = True
    End If
End Function

'Pour les fonctions Variant : KO => Empty après HandleError
Private Function FailVariant(ByVal userMsg As String) As Variant
    HandleError userMsg
    FailVariant = Empty
End Function

'**************************************************************************************
Public Function TablesInfo(Optional ByVal schemaFilter As String = "") As Variant
    Dim v As Variant, p As LongPtr
    If LenB(schemaFilter) > 0 Then
        p = StrPtr(schemaFilter)
    Else
        p = 0
    End If
    If Not CheckOk( _
        DuckVba_TableInfoV(m_h, p, v), "TablesInfo KO:" & IIf(LenB(schemaFilter) > 0, vbCrLf & "schema=" & schemaFilter, vbNullString)) Then
        TablesInfo = Empty
        Exit Function
    End If
    TablesInfo = v
End Function

Public Function ColumnsInfo(ByVal tableFullName As String) As Variant
    Dim v As Variant
    If Not CheckOk(DuckVba_ColumnsInfoV(m_h, StrPtr(tableFullName), v), _
                   "ColumnsInfo KO:", "table=" & tableFullName) Then
        ColumnsInfo = Empty
        Exit Function
    End If
    ColumnsInfo = v
End Function

'connaître la taille du résultat d’un SELECT sans rapatrier toutes les données
Public Sub SelectShape(ByVal selectSql As String, ByRef outRows As Long, ByRef outCols As Long)
    Dim q As String
    q = TrimSQL(selectSql)
    outRows = 0 'valeurs par défaut si erreur
    outCols = 0
    If DuckVba_SelectShapeW(m_h, StrPtr(q), outRows, outCols) = 0 Then
        HandleError "SelectShape KO:" & vbCrLf & Left$(q, 500)
        Exit Sub
    End If
End Sub

Public Sub OpenDuckDb(ByVal dbPath As String)
    If m_h <> 0 Then Me.CloseDuckDb
    m_inTx = False
    m_h = DuckVba_OpenW(StrPtr(dbPath))
    If m_h = 0 Then
        HandleError "OpenDuckDb KO:" & vbCrLf & dbPath
        Exit Sub
    End If
End Sub

Public Sub OpenReadOnly(ByVal dbPath As String)
    If m_h <> 0 Then Me.CloseDuckDb
    m_inTx = False
    m_h = DuckVba_OpenReadOnlyW(StrPtr(dbPath))
    If m_h = 0 Then
        HandleError "OpenDuckDb(RO) KO:" & vbCrLf & dbPath
        Exit Sub
    End If
End Sub

Public Sub CloseDuckDb()
    On Error Resume Next
    If m_h <> 0 Then
        If m_inTx Then Me.Rollback
        DuckVba_Close m_h
        m_h = 0
        m_inTx = False
    End If
End Sub

Public Property Get handle() As LongPtr
    handle = m_h
End Property

'-- Exec / Transactions -----------------------------------------
Public Sub Exec(ByVal sql As String)
    If m_h = 0 Then
        HandleError "Exec: handle nul (DB non ouverte)"
        Exit Sub
    End If
    Dim q As String
    q = TrimSQL(sql)
    If DuckVba_ExecW(m_h, StrPtr(q)) = 0 Then
        HandleError "SQL KO:" & vbCrLf & Left$(q, 500)
        Exit Sub
    End If
End Sub

Public Function QueryFast(ByVal selectSql As String) As Variant

    Dim v As Variant, q As String
    If m_h = 0 Then
        HandleError "QueryFast: handle nul (DB non ouverte)"
        QueryFast = Empty
        Exit Function
    End If
    q = TrimSQL(selectSql)

    If DuckVba_QueryToArrayFastV(m_h, StrPtr(q), v) = 0 Then
        HandleError "QueryFast KO:" & vbCrLf & Left$(q, 500)
        QueryFast = Empty
        Exit Function
    End If
    QueryFast = v

End Function

Public Function ExecOK(ByVal sql As String) As Boolean
    On Error GoTo Oops
    ExecOK = (DuckVba_ExecW(m_h, StrPtr(sql)) <> 0)
    Exit Function
Oops: ExecOK = False
End Function

Public Sub BeginTx()
    If Me.ExecOK("BEGIN TRANSACTION;") Then m_inTx = True
End Sub

Public Sub Commit()
    'If m_inTx Then Call Me.ExecOK("COMMIT;"): m_inTx = False
    If Not m_inTx Then Exit Sub
    If Me.ExecOK("COMMIT;") Then
        m_inTx = False
    Else
        HandleError "COMMIT failed"
        'Optionnel: Me.ExecOK("ROLLBACK;")
        'm_inTx = False  ' selon ta stratégie
    End If
End Sub


Public Sub Rollback()
    If m_inTx Then Call Me.ExecOK("ROLLBACK;"): m_inTx = False
End Sub

'Methode Query Arr avec PowerQuery moins rapide que QueryFast (dll c)
Public Sub SelectToSheet(ByVal selectSql As String, ByVal Target As Worksheet, Optional ByVal topLeft As String = "A1")

    Dim tmp$, p$, q$
    tmp = ThisWorkbook.Path & "\duck_out.csv"
    p = Replace(tmp, "\", "/"): p = Replace(p, "'", "''")
    'q = Trim$(selectSql)
    q = TrimSQL(selectSql)
    Me.Exec "COPY (" & q & ") TO '" & p & "' (FORMAT CSV, HEADER, DELIMITER ',', OVERWRITE 1);"
    Target.Cells.Clear
    With Target.QueryTables.Add(Connection:="TEXT;" & tmp, Destination:=Target.Range(topLeft))
        .TextFileParseType = xlDelimited
        .TextFileCommaDelimiter = True
        .TextFilePlatform = 65001
        .AdjustColumnWidth = True
        .Refresh BackgroundQuery:=False
        .Delete
    End With
    
End Sub

Public Sub CopyToParquet(ByVal selectSql As String, ByVal outParquet As String)

    Dim q As String, p As String
    If m_h = 0 Then
        HandleError "CopyToParquet: handle nul (DB non ouverte)"
        Exit Sub
    End If
    q = TrimSQL(selectSql)
    p = Replace(outParquet, "\", "/")
    If DuckVba_CopyToParquetW(m_h, StrPtr(q), StrPtr(p)) = 0 Then
        HandleError "CopyToParquet KO (DLL):" & vbCrLf & "outParquet=" & outParquet & vbCrLf & "sql=" & Left$(q, 500)
        Exit Sub
    End If
    m_LastError = vbNullString
    
End Sub

Public Sub AppendArray(ByVal tableName As String, ByRef v As Variant, Optional ByVal hasHeader As Boolean = True)
    If DuckVba_AppendArrayV(m_h, StrPtr(tableName), v, Abs(hasHeader)) = 0 Then
        HandleError "AppendArray KO:" & vbCrLf & "table=" & tableName & vbCrLf & "hasHeader=" & CStr(hasHeader)
        Exit Sub
    End If
End Sub

Public Sub AppendAdoRecordset(ByVal rs As Object, ByVal tableName As String, Optional ByVal createIfMissing As Boolean = True)

    If DuckVba_AppendAdoRecordset(m_h, ObjPtr(rs), StrPtr(tableName), Abs(createIfMissing)) = 0 Then
        HandleError "AppendAdoRecordset KO:" & vbCrLf & "table=" & tableName & vbCrLf & "createIfMissing=" & CStr(createIfMissing)
        Exit Sub
    End If
End Sub

Public Sub AppendAdoRecordsetFast(ByVal rs As Object, ByVal tableName As String, Optional ByVal createIfMissing As Boolean = True)

    If DuckVba_AppendAdoRecordsetFast(m_h, ObjPtr(rs), StrPtr(tableName), Abs(createIfMissing)) = 0 Then
        HandleError "AppendAdoRecordsetFast KO:" & vbCrLf & "table=" & tableName & vbCrLf & "createIfMissing=" & CStr(createIfMissing)
        Exit Sub
    End If

End Sub

'-- Temp list / auto-join ---------------------------------------
Public Sub CreateTempList(ByVal tempName As String, ByRef keys As Variant, ByVal sqlType As String)

    If DuckVba_CreateTempListV(m_h, StrPtr(tempName), keys, StrPtr(sqlType)) = 0 Then
        HandleError "CreateTempList KO:" & vbCrLf & "tempName=" & tempName & vbCrLf & "sqlType=" & sqlType
        Exit Sub
    End If
    'm_LastError = ""

End Sub

Public Function SelectWithTempList(ByVal tempName As String, ByRef keys As Variant, ByVal sqlType As String, _
                    ByVal selectOrTable As String, ByVal joinCol As String, ByVal autoJoin As Boolean) As Variant

    Dim v As Variant, pJoin As LongPtr
    If LenB(joinCol) <> 0 Then
        pJoin = StrPtr(joinCol)
    Else
        pJoin = 0&
    End If
    If DuckVba_SelectWithTempList2V(m_h, StrPtr(tempName), keys, StrPtr(sqlType), StrPtr(selectOrTable), pJoin, Abs(autoJoin), v) = 0 Then

        HandleError "SelectWithTempList KO:" & vbCrLf & "tempName=" & tempName & vbCrLf & "sqlType=" & sqlType & vbCrLf & _
                "selectOrTable=" & Left$(selectOrTable, 500) & vbCrLf & "joinCol=" & joinCol & vbCrLf & "autoJoin=" & CStr(autoJoin)

        SelectWithTempList = Empty
        Exit Function
    End If
    'm_LastError = ""
    SelectWithTempList = v

End Function

Public Sub CopyToJsonx(ByVal selectSql As String, ByVal outJson As String, Optional ByVal overwrite As Boolean = True)
    Dim sel As String, p As String

    sel = Trim$(selectSql)
    If Len(sel) = 0 Then Err.Raise 5, , "CopyToJson: selectSql vide."
    If Right$(sel, 1) = ";" Then sel = Left$(sel, Len(sel) - 1)
    If overwrite Then
        On Error Resume Next
        Kill outJson
        On Error GoTo 0
    End If
    Call EnsureFolderExists(outJson)
    p = Replace(outJson, "\", "/")
    Me.Exec "COPY (" & sel & ") TO " & SqlQ(p) & " (FORMAT JSON);"
End Sub

Public Sub CopyToJson(ByVal selectSql As String, ByVal outJson As String, _
    Optional ByVal overwrite As Boolean = True, Optional ByVal boolJsonArray As Boolean = False)
    
    Dim sel As String, p As String

    sel = Trim$(selectSql)
    If Len(sel) = 0 Then Err.Raise 5, , "CopyToJson: selectSql vide."
    If Right$(sel, 1) = ";" Then sel = Left$(sel, Len(sel) - 1)

    If overwrite Then
        On Error Resume Next
        Kill outJson
        On Error GoTo 0
    End If
    EnsureFolderExists outJson
    p = Replace(outJson, "\", "/")
    If boolJsonArray Then
        ' tableau JSON (un seul document JSON)
        Me.Exec "COPY (" & sel & ") TO " & SqlQ(p) & " (FORMAT JSON, ARRAY true);"
    Else
        ' NDJSON : 1 ligne = 1 objet JSON
        Me.Exec "COPY (" & sel & ") TO " & SqlQ(p) & " (FORMAT JSON, ARRAY false);"
    End If
End Sub




' -- Prepared statements (sans 2e classe) ------------------------
Public Function Prepare(ByVal sql As String) As LongPtr
    Dim ps As LongPtr
    ps = DuckVba_PrepareW(m_h, StrPtr(sql))
    If ps = 0 Then
        HandleError "Prepare KO:" & vbCrLf & Left$(sql, 500)
        Prepare = 0
        Exit Function
    End If
    Prepare = ps
End Function

Public Sub PS_BindText(ByVal ps As LongPtr, ByVal idx As Long, ByVal s As String)
    If DuckVba_BindVarcharW(ps, idx, StrPtr(s)) = 0 Then
        HandleError "PS_BindText KO (DLL):" & vbCrLf & "idx=" & CStr(idx) & vbCrLf & "text.len=" & CStr(Len(s))
        Exit Sub
    End If
End Sub

Public Sub PS_BindInt64(ByVal ps As LongPtr, ByVal idx As Long, ByVal v As LongLong)
    If DuckVba_BindInt64(ps, idx, v) = 0 Then
        HandleError "PS_BindInt64 KO (DLL):" & vbCrLf & "idx=" & CStr(idx) & vbCrLf & "v=" & CStr(v)
        Exit Sub
    End If
End Sub

Public Sub PS_BindDouble(ByVal ps As LongPtr, ByVal idx As Long, ByVal v As Double)
    If DuckVba_BindDouble(ps, idx, v) = 0 Then
        HandleError "PS_BindDouble KO (DLL):" & vbCrLf & "idx=" & CStr(idx) & vbCrLf & "v=" & CStr(v)
        Exit Sub
    End If
End Sub

Public Sub PS_Exec(ByVal ps As LongPtr)
    If DuckVba_ExecPrepared(ps) = 0 Then Err.Raise 5, , "ExecPrepared KO"
End Sub

Public Sub PS_CloseDuckDb(ByRef ps As LongPtr)
    If ps <> 0 Then DuckVba_Finalize ps: ps = 0
End Sub

' -- Readers auto (csv/json/parquet) ------------------------------
Public Function ReadToArray(ByVal filePath As String, Optional ByVal tailSql As String = "") As Variant
    Dim p$, ext$, src$, sql$
    p = Replace(filePath, "\", "/")
    ext = LCase$(Mid$(p, InStrRev(p, ".") + 1))

    If ext = "parquet" Or InStr(1, p, ".parquet", vbTextCompare) > 0 Then
        On Error Resume Next: Me.LoadExt "parquet": On Error GoTo 0
        src = "read_parquet(" & SqlQ(p) & ")"
    ElseIf ext = "json" Or InStr(1, p, ".json", vbTextCompare) > 0 Then
        On Error Resume Next: Me.LoadExt "json": On Error GoTo 0
        src = "read_json_auto(" & SqlQ(p) & ")"
    Else
        src = "read_csv_auto(" & SqlQ(p) & ", header=true, sample_size=-1)"
    End If

    sql$ = "SELECT * FROM " & src & IIf(Len(tailSql) > 0, " " & tailSql, "")
    ReadToArray = Me.QueryFast(sql$)
End Function

' === Helpers ===============================================
'Existance d'une table dans le schéma main
Public Function TableExistsSql(ByVal tableName As String) As Boolean
    Dim v As Variant
    v = Me.QueryFast("SELECT 1 FROM information_schema.tables " & _
                     "WHERE table_schema='main' AND table_name=" & SqlQ(tableName) & " LIMIT 1")
    On Error Resume Next
    TableExistsSql = (Not IsEmpty(v)) And (UBound(v, 1) > 1)
End Function

'Quote d'identifiant SQL (pour noms de colonnes/tables)
Public Function QuoteIdent(ByVal s As String) As String
    QuoteIdent = """" & Replace(s, """", """""") & """"
End Function

'Charge ODBC (ou nanodbc) – renvoie True si OK
Public Function EnsureOdbcLoaded() As Boolean

    If Me.TryLoadExt("odbc") Then
        EnsureOdbcLoaded = True
    Else
        EnsureOdbcLoaded = Me.TryLoadExt("nanodbc")
    End If
    
End Function

'Map ADO DataTypeEnum -> DuckDB (typage simple)
Private Function ADOTypeToDuck(ByVal t As Long) As String
    Select Case t
        Case 11:                       ADOTypeToDuck = "BOOLEAN"     ' adBoolean
        Case 2, 3, 17, 18, 19:         ADOTypeToDuck = "INTEGER"     ' small/int variants
        Case 20:                       ADOTypeToDuck = "BIGINT"      ' adBigInt
        Case 4, 5:                     ADOTypeToDuck = "DOUBLE"      ' Single/Double
        Case 6:                        ADOTypeToDuck = "DOUBLE"      ' Currency
        Case 7, 133, 134:              ADOTypeToDuck = "DATE"        ' Date
        Case 135:                      ADOTypeToDuck = "TIMESTAMP"   ' DateTime
        Case 200, 201, 202, 203:       ADOTypeToDuck = "TEXT"        ' (N)Varchar/Memo
        Case Else:                     ADOTypeToDuck = "TEXT"
    End Select
End Function

Private Function AdoToDuckType(ByVal adoType As Long, ByVal size As Long, ByVal prec As Long, ByVal scales As Long) As String
    
    'NOT USED
    Const adBoolean = 11, adTinyInt = 16, adSmallInt = 2, adInteger = 3, adBigInt = 20
    Const adUnsignedTinyInt = 17, adSingle = 4, adDouble = 5, adCurrency = 6
    Const adDecimal = 14, adNumeric = 131
    Const adDate = 7, adDBTimeStamp = 135
    Const adGUID = 72, adVarWChar = 202, adVarChar = 200, adLongVarWChar = 203, adLongVarChar = 201
    Const adLongVarBinary = 205, adVarBinary = 204, adBinary = 128

    Select Case adoType
        Case adBoolean:            AdoToDuckType = "BOOLEAN"
        Case adTinyInt, adSmallInt, adInteger, adUnsignedTinyInt: AdoToDuckType = "INTEGER"
        Case adBigInt:             AdoToDuckType = "BIGINT"
        Case adSingle, adDouble:   AdoToDuckType = "DOUBLE"
        Case adCurrency:           AdoToDuckType = "DECIMAL(19,4)"
        Case adDecimal, adNumeric:
            If prec > 0 Then
                If scales < 0 Then scales = 0
                If prec > 38 Then prec = 38
                AdoToDuckType = "DECIMAL(" & prec & "," & scales & ")"
            Else
                AdoToDuckType = "DECIMAL(18,6)"
            End If
        Case adDate, adDBTimeStamp: AdoToDuckType = "TIMESTAMP"
        Case adGUID:                AdoToDuckType = "UUID"
        Case adVarWChar, adVarChar, adLongVarWChar, adLongVarChar: AdoToDuckType = "VARCHAR"
        Case adVarBinary, adBinary, adLongVarBinary: AdoToDuckType = "BLOB"
        Case Else:                 AdoToDuckType = "VARCHAR"
    End Select
    
End Function

Public Sub CreateTableFromRecordsetSchema(ByVal tableName As String, ByVal rs As Object)
    Dim i As Long, sql As String
    sql = "DROP TABLE IF EXISTS " & QuoteIdent(tableName) & "; CREATE TABLE " & QuoteIdent(tableName) & "("
    For i = 0 To rs.Fields.Count - 1
        If i > 0 Then sql = sql & ", "
        sql = sql & QuoteIdent(rs.Fields(i).name) & " " & ADOTypeToDuck(rs.Fields(i).Type)
    Next
    sql = sql & ");"
    Me.Exec sql
End Sub
'Transforme un Recordset ADO en Variant(2D)
Public Function RecordsetToVariant2D(ByVal rs As Object, Optional ByVal withHeader As Boolean = True) As Variant

    Dim data As Variant, out As Variant, R As Long, C As Long, rows As Long, cols As Long, base As Long

    cols = rs.Fields.Count
    If rs.EOF Then
        RecordsetToVariant2D = Empty
        Exit Function
    End If

    data = rs.GetRows() ' retourne (fields, rows) 0-based
    rows = UBound(data, 2) + 1
    base = IIf(withHeader, 1, 0)
    ReDim out(1 To rows + base, 1 To cols)

    If withHeader Then
        For C = 1 To cols
            out(1, C) = rs.Fields(C - 1).name
        Next
    End If

    For R = 1 To rows
        For C = 1 To cols
            out(R + base, C) = data(C - 1, R - 1)
        Next
    Next
    RecordsetToVariant2D = out
    
End Function

Public Sub Test_ADO_GetRows()

    Const accdbPath As String = "\DbAccess.accdb"
    Const tableName As String = "Clients"
    Const sheetName As String = "TEST_CLIENTS"

    Dim sh As Worksheet, cn As Object, rs As Object, v As Variant

    Set sh = GetOrCreateSheet(sheetName)
    sh.Cells.Clear

    Set cn = CreateObject("ADODB.Connection")
    cn.Open "Provider=Microsoft.ACE.OLEDB.12.0;Data Source=" & accdbPath & ";Persist Security Info=False;"

    Set rs = CreateObject("ADODB.Recordset")
    rs.CursorLocation = 3 ' adUseClient (important pour GetRows "confortable")
    rs.Open "SELECT * FROM [" & tableName & "];", cn, 1, 1  ' adOpenKeyset, adLockReadOnly

    '--- convertit en Variant(2D)
    v = RecordsetToVariant2D(rs, True)
    '--- dump
    If IsEmpty(v) Then
        sh.Range("A1").Value = "Recordset vide"
    Else
        sh.Range("A1").Resize(UBound(v, 1), UBound(v, 2)).Value = v
    End If

    rs.Close: cn.Close
    Set rs = Nothing: Set cn = Nothing
    MsgBox "OK: " & sheetName & " rempli", vbInformation
    
End Sub

Public Function TryLoadExt(ByVal name As String) As Boolean
    On Error Resume Next
        TryLoadExt = (DuckVba_LoadExtW(m_h, StrPtr(name)) <> 0)
    On Error GoTo 0
End Function

Public Sub LoadExt(ByVal name As String)
    On Error GoTo Fail
    If DuckVba_LoadExtW(m_h, StrPtr(name)) = 0 Then
        Err.Raise 5, , "LOAD EXT '" & name & "' KO: " & Native_LastErrorText()
    End If
    Exit Sub
Fail:
    Err.Raise Err.Number, , Err.Description
End Sub

' ========= A) Access -> CSV (late binding, sans référence) =========
' Remplace ta fonction par celle-ci
Public Function Access_Table_To_CSV(ByVal accdbPath As String, ByVal tableName As String, ByVal csvPath As String) As Boolean

    Dim db As New cDuck, ok As Boolean, fso As Object, folder As String, acc$, conn$, pOut$
    
    On Error GoTo Fail

    '0) Prépare le fichier de sortie
    Set fso = CreateObject("Scripting.FileSystemObject")
    folder = fso.GetParentFolderName(csvPath)
    If Len(folder) > 0 Then If Not fso.FolderExists(folder) Then fso.CreateFolder folder
    On Error Resume Next: Kill csvPath: On Error GoTo Fail

    '1) DuckDB en mémoire
    db.Init ThisWorkbook.Path
    db.OpenDuckDb ":memory:"

    ' 2) Tente l’extension ODBC (ou nanodbc)
    If db.EnsureOdbcLoaded Then
        acc = Replace(accdbPath, "\", "/")
        pOut = Replace(csvPath, "\", "/")
        conn = "Driver={Microsoft Access Driver (*.mdb, *.accdb)};Dbq=" & acc & ";Uid=Admin;Pwd=;"

        ' COPY direct -> CSV (HEADER)
        db.Exec "COPY (" & _
                "SELECT * FROM odbc_scan(" & SqlQ(conn) & ", '', " & SqlQ(tableName) & ")" & _
                ") TO " & SqlQ(pOut) & " (FORMAT CSV, HEADER, DELIMITER ',', QUOTE '""');"

        db.CloseDuckDb
        Access_Table_To_CSV = (Dir$(csvPath, vbNormal) <> "")
        Exit Function
    End If

    ' 3) Fallback si ODBC indisponible -> passe par ADO + DuckDB COPY
    ok = Access_Table_To_CSV_via_ADO(db, accdbPath, tableName, csvPath)
    db.CloseDuckDb
    Access_Table_To_CSV = ok
    Exit Function

Fail:
    On Error Resume Next
    db.CloseDuckDb
    Access_Table_To_CSV = False
End Function

'Helper fallback : ADO -> DuckDB -> COPY CSV
Private Function Access_Table_To_CSV_via_ADO(ByRef db As cDuck, ByVal accdbPath As String, _
                ByVal tableName As String, ByVal csvPath As String) As Boolean

    On Error GoTo Fail

    Dim cn As Object, rs As Object
    
    Set cn = CreateObject("ADODB.Connection")
    cn.Open "Provider=Microsoft.ACE.OLEDB.12.0;Data Source=" & accdbPath & ";Persist Security Info=False;"

    Set rs = CreateObject("ADODB.Recordset")
    rs.CursorLocation = 3 'adUseClient
    rs.Open "[" & tableName & "]", cn, 1, 1   'adOpenKeyset, adLockReadOnly

    'Dépose dans une table temp DuckDB puis COPY
    If rs.EOF Then
        db.Exec "CREATE TABLE IF NOT EXISTS __tmp__(dummy INT); DELETE FROM __tmp__;"
    Else
        db.CreateTableFromRecordsetSchema "__tmp__", rs
        db.AppendAdoRecordset rs, "__tmp__", False
    End If
    rs.Close: cn.Close
    Set rs = Nothing: Set cn = Nothing

    Dim pOut$: pOut = Replace(csvPath, "\", "/")
    db.Exec "COPY __tmp__ TO " & SqlQ(pOut) & " (FORMAT CSV, HEADER, DELIMITER ',', QUOTE '""');"

    Access_Table_To_CSV_via_ADO = (Dir$(csvPath, vbNormal) <> "")
    Exit Function

Fail:
    On Error Resume Next
    If Not rs Is Nothing Then If rs.State <> 0 Then rs.Close
    If Not cn Is Nothing Then If cn.State <> 0 Then cn.Close
    Set rs = Nothing: Set cn = Nothing
    Access_Table_To_CSV_via_ADO = False
    
End Function

' --- Dict helper (wrap DuckVba_SelectToDictW) -------------------
Public Sub SelectToDictRow2D(ByVal selectSql As String, ByVal keyCol As String, ByRef dict As Object, _
                    Optional ByVal clearFirst As Boolean = True, Optional ByVal onDupMode As Long = 1)

    If dict Is Nothing Then Set dict = CreateObject("Scripting.Dictionary")
    If DuckVba_SelectToDictW(m_h, StrPtr(selectSql), StrPtr(keyCol), _
                             ObjPtr(dict), Abs(clearFirst), onDupMode) = 0 Then
        HandleError "SelectToDict KO:" & vbCrLf & "keyCol=" & keyCol & vbCrLf & Left$(selectSql, 500)
        Exit Sub
    End If

End Sub

Public Sub SelectToCsv(ByVal selectSql As String, ByVal outCsv As String)

    Dim q As String, p As String
    q = TrimSQL(selectSql)
    p = Replace(outCsv, "\", "/")
    If DuckVba_SelectToCsvW(m_h, StrPtr(q), StrPtr(p)) = 0 Then
        HandleError "SelectToCsv KO:" & vbCrLf & "outCsv=" & outCsv & vbCrLf & Left$(q, 500)
        Exit Sub
    End If

End Sub

'Quote "schema.table" en  "schema"."table"
'Si l'utilisateur passe juste "clients", ça renvoie "clients"
Public Function QuoteIdentPath(ByVal fullName As String) As String

    Dim parts() As String, i As Long

    parts = Split(fullName, ".")
    If UBound(parts) = 0 Then
        ' juste "table"
        QuoteIdentPath = """" & Replace(parts(0), """", """""") & """"
    ElseIf UBound(parts) = 1 Then
        ' "schema.table"
        QuoteIdentPath = """" & Replace(parts(0), """", """""") & """" & ".""" & Replace(parts(1), """", """""") & """"
    Else
        ' cas tordu genre a.b.c -> on quote tout en les rejoignant avec .
        QuoteIdentPath = ""
        For i = LBound(parts) To UBound(parts)
            If i > LBound(parts) Then QuoteIdentPath = QuoteIdentPath & "."
            QuoteIdentPath = QuoteIdentPath & """" & Replace(parts(i), """", """""") & """"
        Next i
    End If
End Function

' ImportCsvReplace :
'   - DROP TABLE IF EXISTS
'   - recrée la table depuis le CSV (auto-typage DuckDB)
'
' => résultat : on remplace complètement l'ancienne table
Public Sub ImportCsvReplace(ByVal csvPath As String, ByVal tableFullName As String)

    Dim ok As Long, dropSql As String

    '1) Drop la table si elle existe (schema/table géré)
    dropSql = "DROP TABLE IF EXISTS " & Me.QuoteIdentPath(tableFullName) & ";"
    If DuckVba_ExecW(m_h, StrPtr(dropSql)) = 0 Then
        Err.Raise 5, , "ImportCsvReplace (DROP) KO: " & Native_LastErrorText()
    End If

    '2) Réimporte en recréant la table
    ok = DuckVba_ReadCsvToTableW(m_h, StrPtr(tableFullName), StrPtr(csvPath), 1)
    If ok = 0 Then
        Err.Raise 5, , "ImportCsvReplace KO: " & Native_LastErrorText()
    End If
    
End Sub

Public Sub UpsertFromArray(ByVal tableName As String, ByRef data2D As Variant, ByVal headerRow As Long, ByVal keyColsCsv As String)

    Dim ok As Long
    ok = DuckVba_UpsertFromArrayV(m_h, StrPtr(tableName), data2D, headerRow, StrPtr(keyColsCsv))
    If ok = 0 Then
        ' Log + message (selon ErrorMode) mais NON bloquant
        HandleError "UpsertFromArray KO (DLL):" & vbCrLf & "table=" & tableName & vbCrLf & _
                    "headerRow=" & CStr(headerRow) & vbCrLf & "keys=" & keyColsCsv
        ' --- fallback : MERGE non supporté => UPDATE + INSERT manuels
        On Error GoTo FallbackFail
        FallbackUpsertNoMerge tableName, data2D, headerRow, keyColsCsv
        Exit Sub
FallbackFail:
        ' Si le fallback échoue, on log l’erreur VBA (et on sort)
        HandleError "UpsertFromArray fallback KO:" & vbCrLf & "table=" & tableName & vbCrLf & "err=" & Err.Description
        Exit Sub
    End If

End Sub

Private Sub FallbackUpsertNoMerge(ByVal tableName As String, ByRef arr As Variant, ByVal headerRow As Long, ByVal keyColsCsv As String)

    Dim keysArr() As String, colsQuoted As String, setList As String, whereUpdate As String, whereExists As String, insCols As String, insVals As String
    Dim ncols     As Long, C As Long, i As Long, ok As Long, isKey As Boolean, head As String

    'clés normalisées
    keysArr = Split(keyColsCsv, ",")
    For i = LBound(keysArr) To UBound(keysArr)
        keysArr(i) = Trim$(keysArr(i))
    Next
    ncols = UBound(arr, 2)

    For C = 1 To ncols
        head = CStr(arr(headerRow, C))
        If Len(head) > 0 Then
            ' pour CREATE AS (clone du schéma/ordre des colonnes)
            If Len(colsQuoted) > 0 Then colsQuoted = colsQuoted & ", "
            colsQuoted = colsQuoted & """" & head & """"
        End If
    Next
    'table tampon
    Me.Exec "DROP TABLE IF EXISTS ""__tmp_upsert"";"
    Me.Exec "CREATE TABLE ""__tmp_upsert"" AS SELECT " & colsQuoted & " FROM """ & tableName & """ WHERE 0;"
    'charger l’array dans la table tampon (on saute la ligne d’entête)
    ok = DuckVba_AppendArrayV(m_h, StrPtr("__tmp_upsert"), arr, 1)
    If ok = 0 Then Err.Raise 5, , "AppendArrayV failed: " & Native_LastErrorText()
    'construire SET / WHERE / INSERT
    setList = "": whereUpdate = "": whereExists = "": insCols = "": insVals = ""
    For C = 1 To ncols
        head = CStr(arr(headerRow, C))
        If Len(head) = 0 Then GoTo NextC

        'est-ce une clé ?
        isKey = False
        For i = LBound(keysArr) To UBound(keysArr)
            If StrComp(keysArr(i), head, vbTextCompare) = 0 Then
                isKey = True
                Exit For
            End If
        Next i

        If isKey Then
            'WHERE pour UPDATE : table cible par son nom (pas d’alias)
            If Len(whereUpdate) > 0 Then whereUpdate = whereUpdate & " AND "
            whereUpdate = whereUpdate & """" & tableName & """.""" & head & """ = s.""" & head & """"

            'WHERE pour EXISTS : alias t
            If Len(whereExists) > 0 Then whereExists = whereExists & " AND "
            whereExists = whereExists & "t.""" & head & """ = s.""" & head & """"
        Else
            'SET : LHS non qualifié (DuckDB l’exige)
            If Len(setList) > 0 Then setList = setList & ", "
            setList = setList & """" & head & """ = s.""" & head & """"
        End If
        'listes d’INSERT
        If Len(insCols) > 0 Then
            insCols = insCols & ", """ & head & """"
            insVals = insVals & ", s.""" & head & """"
        Else
            insCols = """" & head & """"
            insVals = "s.""" & head & """"
        End If
NextC:
    Next

    'sécurité : si toutes les colonnes sont des clés, faire un SET tautologique
    If Len(setList) = 0 And UBound(keysArr) >= LBound(keysArr) Then
        setList = """" & keysArr(LBound(keysArr)) & """ = """ & keysArr(LBound(keysArr)) & """"  ' no-op
    End If

    'UPDATE … FROM …
    Me.Exec _
        "UPDATE """ & tableName & """ " & _
        "SET " & setList & " " & _
        "FROM ""__tmp_upsert"" AS s " & _
        "WHERE " & whereUpdate & ";"
    'INSERT manquants
    Me.Exec _
        "INSERT INTO """ & tableName & """ (" & insCols & ") " & _
        "SELECT " & insVals & " FROM ""__tmp_upsert"" s " & _
        "WHERE NOT EXISTS (" & _
        "  SELECT 1 FROM """ & tableName & """ t WHERE " & whereExists & ");"
    'nettoyage
    Me.Exec "DROP TABLE IF EXISTS ""__tmp_upsert"";"
    
End Sub

'======================== 2) CLASSE cDuck : Méthodes à AJOUTER ======================
' Colle ces méthodes DANS ta classe cDuck (par ex. juste après SelectToDictRow2D)

' Remplit un Scripting.Dictionary (clé?valeur) depuis un SELECT.
' - keyCol : nom de la colonne clé
' - valCol : nom de la colonne valeur ; si "" et que le SELECT retourne exactement 2 colonnes,
'            la DLL choisit automatiquement l’autre colonne comme valeur.
' - clearFirst : True = dict.RemoveAll
' - onDupMode : 0=ignore les doublons, 1=remplace la valeur existante

Public Sub FillDictFlat(ByVal selectSql As String, ByVal keyCol As String, ByVal valCol As String, ByRef dict As Object, _
                        Optional ByVal clearFirst As Boolean = True, Optional ByVal onDupMode As Long = 1)

    Dim pVal As LongPtr, ok As Long, q As String

    If dict Is Nothing Then Set dict = CreateObject("Scripting.Dictionary")
    q = TrimSQL(selectSql)
    If LenB(valCol) = 0 Then
        pVal = 0&   'NULL côté DLL => auto si 2 colonnes
    Else
        pVal = StrPtr(valCol)
    End If
    ok = DuckVba_SelectToDictFlatW(m_h, StrPtr(q), StrPtr(keyCol), pVal, ObjPtr(dict), Abs(clearFirst), onDupMode)
    If ok = 0 Then
        HandleError "FillDictFlat KO (DLL):" & vbCrLf & "keyCol=" & keyCol & vbCrLf & _
                    IIf(LenB(valCol) = 0, "valCol=(auto)", "valCol=" & valCol) & vbCrLf & "sql=" & Left$(q, 500)
        Exit Sub
    End If

End Sub

'Fct FillDictFlat
Public Function SelectToDictFlat(ByVal selectSql As String, ByVal keyCol As String, _
        Optional ByVal valCol As String = "", Optional ByVal clearFirst As Boolean = True, Optional ByVal onDupMode As Long = 1) As Dictionary
    
    Dim d As New Dictionary
    Set d = CreateObject("Scripting.Dictionary")
    Me.FillDictFlat selectSql, keyCol, valCol, d, clearFirst, onDupMode
    Set SelectToDictFlat = d
    Set d = Nothing
    
End Function

' --- Dict helper (wrap DuckVba_SelectToDictValsColsW) -----------
Public Sub SelectToDictRow1D(ByVal selectSql As String, ByVal keyCol As String, ByRef dict As Object, _
                        Optional ByVal valueColsCsv As String = vbNullString, Optional ByVal clearFirst As Boolean = True, Optional ByVal onDupMode As Long = 1)

    Dim pCols As LongPtr, ok As Long, q As String

    If dict Is Nothing Then Set dict = CreateObject("Scripting.Dictionary")
    q = TrimSQL(selectSql)

    If LenB(valueColsCsv) = 0 Then
        pCols = 0&         'NULL -> default: toutes colonnes sauf clé
    Else
        pCols = StrPtr(valueColsCsv)
    End If

    ok = DuckVba_SelectToDictValsColsW(m_h, StrPtr(q), StrPtr(keyCol), pCols, ObjPtr(dict), Abs(clearFirst), onDupMode)
    If ok = 0 Then
        HandleError "SelectToDictRow1D KO (DLL):" & vbCrLf & "keyCol=" & keyCol & vbCrLf & IIf(LenB(valueColsCsv) = 0, "cols=(default)", "cols=" & valueColsCsv) & vbCrLf & "sql=" & Left$(q, 500)
        Exit Sub
    End If

End Sub

Public Sub FrameFromValue(ByVal frameName As String, ByRef data2D As Variant, ByVal hasHeader As Boolean, _
                          Optional ByVal makeTemp As Boolean = True)

    Dim ok As Long
    ok = DuckVba_FrameFromValue(m_h, StrPtr(frameName), data2D, Abs(hasHeader), Abs(makeTemp))
    If ok = 0 Then
        HandleError "FrameFromValue KO (DLL):" & vbCrLf & "frame=" & frameName & vbCrLf & "hasHeader=" & CStr(hasHeader) & ", makeTemp=" & CStr(makeTemp)
        Exit Sub
    End If

End Sub

Public Function Scalar(ByVal selectSql As String) As Variant

    Dim v As Variant, q As String, ok As Long
    q = TrimSQL(selectSql)
    ok = DuckVba_ScalarV(m_h, StrPtr(q), v)
    If ok = 0 Then
        HandleError "Scalar KO (DLL):" & vbCrLf & Left$(q, 500)
        Scalar = Empty
        Exit Function
    End If
    Scalar = v

End Function

Public Function ScalarDbl(ByVal selectSql As String, Optional ByVal defaultValue As Double = 0#) As Double
    Dim v As Variant
    v = Me.Scalar(selectSql)
    If IsEmpty(v) Or IsNull(v) Or v = "" Then
        ScalarDbl = defaultValue
    Else
        ScalarDbl = CDbl(v)
    End If
End Function

Public Function ScalarLong(ByVal selectSql As String, Optional ByVal defaultValue As Long = 0) As Long
    Dim v As Variant
    v = Me.Scalar(selectSql)
    If IsEmpty(v) Or IsNull(v) Or v = "" Then
        ScalarLong = defaultValue
    Else
        ScalarLong = CLng(v)
    End If
End Function

Public Function ScalarText(ByVal selectSql As String, Optional ByVal defaultValue As String = "") As String
    Dim v As Variant
    v = Me.Scalar(selectSql)
    If IsEmpty(v) Or IsNull(v) Then
        ScalarText = defaultValue
    Else
        ScalarText = CStr(v)
    End If
End Function

Public Function ScalarDate(ByVal selectSql As String, Optional ByVal defaultValue As Date = 0#) As Date
    Dim v As Variant
    v = Me.Scalar(selectSql)
    If IsEmpty(v) Or IsNull(v) Or v = "" Then
        ScalarDate = defaultValue
    Else
        ScalarDate = CDate(v)
    End If
End Function

'Existence d'une table/vue (main, temp, autre schéma)
'Exemple: TableExists("main.clients"), TableExists("temp.__tmp_upsert")
Public Function TableExists(ByVal tableFullName As String) As Boolean
    If m_h = 0 Then
        TableExists = False
    Else
        TableExists = (DuckVba_TableExistsW(m_h, StrPtr(tableFullName)) <> 0)
    End If
End Function

'Existence d'une colonne dans une table (via DLL)
Public Function ColumnExists(ByVal tablePath As String, ByVal colName As String) As Boolean
    If m_h = 0 Then
        ColumnExists = False
    Else
        ColumnExists = (DuckVba_ColumnExistsW(m_h, StrPtr(tablePath), StrPtr(colName)) <> 0)
    End If
End Function

'Renomme une table (oldName peut contenir un schéma : "main.MaTable")
Public Sub RenameTable(ByVal oldName As String, ByVal newName As String)

    If m_h = 0 Then
        HandleError "RenameTable KO: handle nul" & vbCrLf & "old=" & oldName & vbCrLf & "new=" & newName
        Exit Sub
    End If
    If DuckVba_RenameTableW(m_h, StrPtr(oldName), StrPtr(newName)) = 0 Then
        HandleError "RenameTable KO (DLL):" & vbCrLf & "old=" & oldName & vbCrLf & "new=" & newName
        Exit Sub
    End If

End Sub

'Renomme une colonne dans une table
'tableName : "Clients" ou "main.Clients"
Public Sub RenameColumn(ByVal tableName As String, ByVal oldCol As String, ByVal newCol As String)

    If m_h = 0 Then
        HandleError "RenameColumn KO: handle nul" & vbCrLf & "table=" & tableName & vbCrLf & _
                    "oldCol=" & oldCol & vbCrLf & "newCol=" & newCol
        Exit Sub
    End If
    If DuckVba_RenameColumnW(m_h, StrPtr(tableName), StrPtr(oldCol), StrPtr(newCol)) = 0 Then
        HandleError "RenameColumn KO (DLL):" & vbCrLf & "table=" & tableName & vbCrLf & _
                    "oldCol=" & oldCol & vbCrLf & "newCol=" & newCol
        Exit Sub
    End If

End Sub

Public Function PrepStatQueryArray(ByVal ps As LongPtr) As Variant

    Dim v As Variant
    If ps = 0 Then
        HandleError "PrepStatQueryArray KO: ps nul"
        PrepStatQueryArray = Empty
        Exit Function
    End If
    If DuckVba_ExecPreparedToArrayV(ps, v) = 0 Then
        HandleError "PrepStatQueryArray KO (ExecPreparedToArrayV):" & vbCrLf & "ps=" & CStr(ps)
        PrepStatQueryArray = Empty
        Exit Function
    End If
    PrepStatQueryArray = v

End Function

'***************************** LOG *****************************
Public Property Get ErrorMode() As Long
    ErrorMode = m_ErrorMode
End Property

Public Property Let ErrorMode(ByVal v As Long)
    m_ErrorMode = v
End Property

Public Property Get LastError() As String
    LastError = m_LastError
End Property

Public Property Get LogFilePath() As String
    If m_LogFilePath = "" Then
        LogFilePath = m_basePath & "\duckdb_errors.log"
    Else
        LogFilePath = m_LogFilePath
    End If
End Property

Public Property Let LogFilePath(ByVal p As String)
    m_LogFilePath = p
End Property

Private Sub LogErrorToFile(ByVal msg As String)
    On Error Resume Next
    Dim f As Integer
    f = FreeFile
    Open Me.LogFilePath For Append As #f
    Print #f, Format$(Now, "yyyy-mm-dd hh:nn:ss"); " - "; msg
    Close #f
End Sub


Private Function ObjTag() As String
    ObjTag = "cDuck@" & Hex$(ObjPtr(Me))
End Function

Private Sub HandleError(ByVal userMsg As String, Optional ByVal errNumber As Long = 5)

    Dim fullMsg As String, dllErr As String
    
    dllErr = Native_LastErrorText()
    If dllErr <> "" Then
        fullMsg = userMsg & vbCrLf & "DLL says: " & dllErr
    Else
        fullMsg = userMsg
    End If
    m_LastError = fullMsg
    
    Select Case m_ErrorMode
        Case demRaise
            Call LogErrorToFile(fullMsg)
            Err.Raise errNumber, "cDuck", fullMsg
        Case demMsgBox
            MsgBox fullMsg, vbOKOnly, "DuckDB / VBA"
        Case demLogOnly
            Call LogErrorToFile(fullMsg)
    End Select
    
End Sub

