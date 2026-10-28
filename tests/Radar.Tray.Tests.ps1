# ==========================================
# Tests de las funciones de datos del dashboard (Radar-Tray.ps1).
# No abre ventanas: solo parseo de informes y utilidades.
# ==========================================

BeforeAll {
    $script:trayPath = (Resolve-Path (Join-Path $PSScriptRoot '..\Radar-Tray.ps1')).Path

    $tokens = $null
    $errores = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:trayPath, [ref]$tokens, [ref]$errores)

    if ($errores.Count -gt 0) {
        throw "Radar-Tray.ps1 tiene $($errores.Count) errores de sintaxis."
    }

    foreach ($nombre in @('Read-InformesRadar', 'Get-TareasRadar')) {
        $fn = $ast.FindAll({
                param($nodo)
                $nodo -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $nodo.Name -eq $nombre
            }, $true)[0]

        if (-not $fn) { throw "No se encontro la funcion '$nombre' en Radar-Tray.ps1." }
        . ([scriptblock]::Create($fn.Extent.Text))
    }

    $script:dirLogs = Join-Path ([System.IO.Path]::GetTempPath()) 'radar-tray-logs'
    $script:PatronTarea = 'Seguridad - *'
    $script:TareaDash = 'Seguridad - Dashboard Radar'

    function New-LogPrueba {
        param(
            [string]$Dir,
            [string]$NombreArchivo,
            [int]$Criticos = 0,
            [int]$Avisos = 0,
            [string]$Fecha = '01/01/2026 10:00:00',
            [string]$Elevado = 'Si'
        )
        $lineas = @(
            '=================================================================='
            ' RADAR DE SEGURIDAD - INFORME DE EJECUCION'
            '=================================================================='
            "Fecha     : $Fecha"
            'Equipo    : TEST'
            'Usuario   : tester'
            "Elevado   : $Elevado"
            'Evento    : Application / Seguridad-Port22 / ID 1001 (Error)'
            "Resultado : $Criticos criticos, $Avisos avisos, 0 informativos"
            ''
        )
        Set-Content -Path (Join-Path $Dir $NombreArchivo) -Value $lineas -Encoding UTF8
    }
}

Describe 'Informes del dashboard' {

    BeforeEach {
        $script:dir = Join-Path ([System.IO.Path]::GetTempPath()) ("radar-tray-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:dir -Force | Out-Null
    }

    AfterEach {
        if ($script:dir -and (Test-Path $script:dir)) {
            Remove-Item -Path $script:dir -Recurse -Force
        }
    }

    It 'devuelve lista vacia si el directorio no existe' {
        @(Read-InformesRadar -Directorio (Join-Path $script:dir 'nada') -Maximo 10).Count | Should -Be 0
    }

    It 'lee los campos del encabezado' {
        New-LogPrueba -Dir $script:dir -NombreArchivo 'radar-20260101-100000.log' -Criticos 2 -Avisos 3

        $r = @(Read-InformesRadar -Directorio $script:dir -Maximo 10)

        $r.Count | Should -Be 1
        $r[0].Criticos | Should -Be 2
        $r[0].Avisos | Should -Be 3
        $r[0].Informativos | Should -Be 0
        $r[0].Elevado | Should -Be 'Si'
        $r[0].Equipo | Should -Be 'TEST'
        $r[0].Evento | Should -Match 'ID 1001'
        $r[0].Fecha.ToString('dd/MM/yyyy HH:mm') | Should -Be '01/01/2026 10:00'
        (Split-Path $r[0].Archivo -Leaf) | Should -Be 'radar-20260101-100000.log'
    }

    It 'ordena del mas nuevo al mas viejo' {
        New-LogPrueba -Dir $script:dir -NombreArchivo 'radar-20260101-080000.log' -Fecha '01/01/2026 08:00:00'
        New-LogPrueba -Dir $script:dir -NombreArchivo 'radar-20260102-080000.log' -Fecha '02/01/2026 08:00:00'
        New-LogPrueba -Dir $script:dir -NombreArchivo 'radar-20260103-080000.log' -Fecha '03/01/2026 08:00:00'

        (Get-Item (Join-Path $script:dir 'radar-20260101-080000.log')).LastWriteTime = (Get-Date).AddMinutes(-30)
        (Get-Item (Join-Path $script:dir 'radar-20260102-080000.log')).LastWriteTime = (Get-Date).AddMinutes(-20)
        (Get-Item (Join-Path $script:dir 'radar-20260103-080000.log')).LastWriteTime = (Get-Date).AddMinutes(-10)

        $r = @(Read-InformesRadar -Directorio $script:dir -Maximo 10)

        $r.Count | Should -Be 3
        (Split-Path $r[0].Archivo -Leaf) | Should -Be 'radar-20260103-080000.log'
        (Split-Path $r[2].Archivo -Leaf) | Should -Be 'radar-20260101-080000.log'
    }

    It 'respeta el maximo pedido' {
        1..5 | ForEach-Object {
            New-LogPrueba -Dir $script:dir -NombreArchivo ("radar-2026010{0}-090000.log" -f $_)
        }

        @(Read-InformesRadar -Directorio $script:dir -Maximo 2).Count | Should -Be 2
    }

    It 'no falla con un informe corrupto o vacio' {
        Set-Content -Path (Join-Path $script:dir 'radar-20260101-000000.log') -Value 'basura' -Encoding ASCII
        New-Item -ItemType File -Path (Join-Path $script:dir 'radar-20260101-000001.log') | Out-Null

        $r = @(Read-InformesRadar -Directorio $script:dir -Maximo 10)

        $r.Count | Should -Be 2
        $r[0].Criticos | Should -Be 0
        $r[0].Avisos | Should -Be 0
        $r[0].Archivo | Should -Exist
    }

    It 'ignora archivos que no son informes' {
        New-LogPrueba -Dir $script:dir -NombreArchivo 'radar-20260101-100000.log' -Criticos 1
        Set-Content -Path (Join-Path $script:dir 'otra-cosa.log') -Value 'x' -Encoding ASCII
        Set-Content -Path (Join-Path $script:dir 'radar.txt') -Value 'x' -Encoding ASCII

        @(Read-InformesRadar -Directorio $script:dir -Maximo 10).Count | Should -Be 1
    }
}
