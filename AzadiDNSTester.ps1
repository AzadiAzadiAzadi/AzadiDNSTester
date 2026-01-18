# ==============================================================================
# Azadi DNS Tester - PowerShell Edition (No Dependencies)
# ==============================================================================
# Tests DNS servers from dns_servers.txt and saves working ones to working_dns.txt
# Supports ANY input format - extracts ALL IPv4 addresses automatically
# No external dependencies - uses only built-in cmdlets
# Supports PowerShell 5.1+ (uses runspaces) and PowerShell 7+ (uses -Parallel)
# ==============================================================================

param(
    [string]$InputFile = "",
    [string]$OutputFile = "",
    [switch]$NonInteractive,
    [int]$Workers = 0,
    [int]$Timeout = 0,
    [string]$Domain = ""
)

# Get script directory
$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $ScriptDir) { $ScriptDir = Get-Location }

# Set default file paths
if (-not $InputFile) { $InputFile = Join-Path $ScriptDir "dns_servers.txt" }
if (-not $OutputFile) { $OutputFile = Join-Path $ScriptDir "working_dns.txt" }

# Defaults
$DEFAULT_WORKERS = 100
$DEFAULT_TIMEOUT = 3
$DEFAULT_DOMAIN = "google.com"

# Thread-safe collections
$script:WorkingServers = [System.Collections.Concurrent.ConcurrentBag[PSObject]]::new()
$script:FileLock = [System.Object]::new()

# ==============================================================================
# Utility Functions
# ==============================================================================

function Write-ColorOutput {
    param(
        [string]$Message,
        [string]$Color = "White"
    )
    Write-Host $Message -ForegroundColor $Color
}

function Get-IPv4Addresses {
    param([string]$FilePath)
    
    if (-not (Test-Path $FilePath)) {
        return @()
    }

    # Stream parsing to avoid loading huge files into memory and to reduce the
    # "stuck" feeling when dns_servers.txt is large.
    $ipPattern = '\b(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\b'
    $ipRegex = [regex]::new($ipPattern)

    $uniqueSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $totalCount = 0

    foreach ($line in (Get-Content -Path $FilePath -ReadCount 2000)) {
        foreach ($m in $ipRegex.Matches(($line -join "`n"))) {
            $totalCount++
            [void]$uniqueSet.Add($m.Value)
        }
    }

    return @{
        UniqueIPs = @($uniqueSet)
        TotalCount = $totalCount
        UniqueCount = $uniqueSet.Count
    }
}

function New-SampleFile {
    param([string]$FilePath)
    
    $sampleServers = @(
        "1.1.1.1",
        "1.0.0.1",
        "8.8.8.8",
        "8.8.4.4",
        "9.9.9.9",
        "208.67.222.222",
        "208.67.220.220",
        "4.2.2.1",
        "4.2.2.2"
    )
    
    $sampleServers | Out-File -FilePath $FilePath -Encoding UTF8
    Write-ColorOutput "Created sample $FilePath with $($sampleServers.Count) servers" -Color Cyan
}

function Write-OutputHeader {
    param(
        [string]$FilePath,
        [string]$Domain
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $header = @(
        "# Working DNS servers - Tested: $timestamp",
        "# Test domain: $Domain",
        "# Format: IP (response_time_ms)"
    )
    
    $header | Out-File -FilePath $FilePath -Encoding UTF8
}

function Save-WorkingServer {
    param(
        [string]$FilePath,
        [string]$Server,
        [int]$ResponseTime
    )
    
    $line = "$Server (${ResponseTime}ms)"
    
    # Thread-safe append
    [System.Threading.Monitor]::Enter($script:FileLock)
    try {
        Add-Content -Path $FilePath -Value $line -Encoding UTF8
    }
    finally {
        [System.Threading.Monitor]::Exit($script:FileLock)
    }
}

function Invoke-NslookupQuery {
    param(
        [string]$Server,
        [string]$Domain,
        [int]$TimeoutSeconds
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "nslookup"
    $psi.Arguments = "$Domain $Server"
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    $process.Start() | Out-Null
    $script:NslookupStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    $completed = $process.WaitForExit([math]::Max(1, $TimeoutSeconds) * 1000)
    $script:NslookupStopwatch.Stop()
    if (-not $completed) {
        try { $process.Kill() } catch { }
        return @{ Success = $false; ResolvedIP = $null; Error = "Timeout" }
    }

    if ($process.ExitCode -ne 0) {
        return @{ Success = $false; ResolvedIP = $null; Error = "nslookup error" }
    }

    $output = $process.StandardOutput.ReadToEnd()
    $addresses = [regex]::Matches($output, '(?im)^Address(?:es)?:\s*(\d+\.\d+\.\d+\.\d+)')
    if ($addresses.Count -ge 2) {
        # First is usually the DNS server IP; later ones are answers.
        return @{ Success = $true; ResolvedIP = $addresses[$addresses.Count - 1].Groups[1].Value; Error = $null }
    }
    elseif ($addresses.Count -eq 1) {
        # Sometimes nslookup only prints one Address line; treat as success but uncertain.
        return @{ Success = $true; ResolvedIP = $addresses[0].Groups[1].Value; Error = $null }
    }

    return @{ Success = $false; ResolvedIP = $null; Error = "No answer" }
}

# ==============================================================================
# DNS Testing Functions
# ==============================================================================

function Test-DnsServer {
    param(
        [string]$Server,
        [string]$Domain,
        [int]$TimeoutSeconds
    )
    
    $result = @{
        Server = $Server
        Success = $false
        ResponseTime = 0
        ResolvedIP = $null
        Error = $null
    }
    
    try {
        # Use nslookup so we can enforce TimeoutSeconds (Resolve-DnsName can hang).
        $q = Invoke-NslookupQuery -Server $Server -Domain $Domain -TimeoutSeconds $TimeoutSeconds

        if ($q.Success) {
            $result.Success = $true
            $result.ResolvedIP = $q.ResolvedIP
            $result.ResponseTime = [math]::Round($script:NslookupStopwatch.ElapsedMilliseconds)
        }
        else {
            $result.Error = $q.Error
        }
    }
    catch [System.Management.Automation.CommandNotFoundException] {
        $result.Error = "No DNS tool available"
    }
    catch {
        if ($script:NslookupStopwatch) {
            $script:NslookupStopwatch.Stop()
            $result.ResponseTime = [math]::Round($script:NslookupStopwatch.ElapsedMilliseconds)
        }
        $result.Error = $_.Exception.Message
        if ($result.Error.Length -gt 30) {
            $result.Error = $result.Error.Substring(0, 30) + "..."
        }
    }
    
    return $result
}

# ==============================================================================
# User Input Functions
# ==============================================================================

function Get-WorkerCount {
    Write-Host ""
    Write-Host "Workers (parallel tests, default: $DEFAULT_WORKERS, max: 500):"
    Write-Host "  Enter number (1-500) or press Enter for $DEFAULT_WORKERS"
    $choice = Read-Host "Workers"
    
    if ([string]::IsNullOrWhiteSpace($choice)) {
        return $DEFAULT_WORKERS
    }
    
    $num = 0
    if ([int]::TryParse($choice, [ref]$num) -and $num -ge 1 -and $num -le 500) {
        return $num
    }
    
    Write-ColorOutput "Invalid! Using default: $DEFAULT_WORKERS" -Color Yellow
    return $DEFAULT_WORKERS
}

function Get-TimeoutValue {
    Write-Host ""
    Write-Host "Timeout per test (seconds, default: $DEFAULT_TIMEOUT, range: 1-10):"
    Write-Host "  Enter number (1-10) or press Enter for $DEFAULT_TIMEOUT"
    $choice = Read-Host "Timeout"
    
    if ([string]::IsNullOrWhiteSpace($choice)) {
        return $DEFAULT_TIMEOUT
    }
    
    $num = 0
    if ([int]::TryParse($choice, [ref]$num) -and $num -ge 1 -and $num -le 10) {
        return $num
    }
    
    Write-ColorOutput "Invalid! Using default: $DEFAULT_TIMEOUT" -Color Yellow
    return $DEFAULT_TIMEOUT
}

function Get-TestDomain {
    $domains = @("google.com", "cloudflare.com", "example.com")
    
    Write-Host ""
    Write-Host "Test domains (enter number 1-3 or type domain):"
    Write-Host "  1. google.com"
    Write-Host "  2. cloudflare.com"
    Write-Host "  3. example.com"
    Write-Host "  or type your own domain"
    $choice = Read-Host "Enter choice (1-3 or domain)"
    
    if ([string]::IsNullOrWhiteSpace($choice)) {
        return "google.com"
    }
    
    switch ($choice) {
        "1" { return "google.com" }
        "2" { return "cloudflare.com" }
        "3" { return "example.com" }
        default {
            if ($choice -match '\.' -and $choice -notmatch '^https?://') {
                return $choice
            }
            Write-ColorOutput "Invalid! Using default: google.com" -Color Yellow
            return "google.com"
        }
    }
}

# ==============================================================================
# Parallel Execution Functions
# ==============================================================================

# Build a minimal DNS query packet for A record lookup
function Build-DnsQuery {
    param([string]$Domain)
    
    # Transaction ID (random)
    $id = [byte[]]@((Get-Random -Maximum 256), (Get-Random -Maximum 256))
    
    # Flags: standard query, recursion desired
    $flags = [byte[]]@(0x01, 0x00)
    
    # Questions: 1, Answers: 0, Authority: 0, Additional: 0
    $counts = [byte[]]@(0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)
    
    # Encode domain name
    $domainBytes = [System.Collections.Generic.List[byte]]::new()
    foreach ($label in $Domain.Split('.')) {
        $domainBytes.Add([byte]$label.Length)
        $domainBytes.AddRange([System.Text.Encoding]::ASCII.GetBytes($label))
    }
    $domainBytes.Add(0x00)  # Null terminator
    
    # Query type (A = 1) and class (IN = 1)
    $queryType = [byte[]]@(0x00, 0x01, 0x00, 0x01)
    
    # Combine all parts
    $query = [System.Collections.Generic.List[byte]]::new()
    $query.AddRange($id)
    $query.AddRange($flags)
    $query.AddRange($counts)
    $query.AddRange($domainBytes)
    $query.AddRange($queryType)
    
    return @{ Packet = $query.ToArray(); TransactionId = $id }
}

# Parse DNS response to extract IP addresses
function Parse-DnsResponse {
    param([byte[]]$Response, [byte[]]$ExpectedId)
    
    if ($Response.Length -lt 12) { return $null }
    
    # Verify transaction ID
    if ($Response[0] -ne $ExpectedId[0] -or $Response[1] -ne $ExpectedId[1]) {
        return $null
    }
    
    # Check response code (RCODE in lower 4 bits of byte 3)
    $rcode = $Response[3] -band 0x0F
    if ($rcode -ne 0) { return $null }
    
    # Get answer count
    $answerCount = ($Response[6] -shl 8) + $Response[7]
    if ($answerCount -eq 0) { return $null }
    
    # Skip header (12 bytes) and question section
    $pos = 12
    
    # Skip question name
    while ($pos -lt $Response.Length -and $Response[$pos] -ne 0) {
        if (($Response[$pos] -band 0xC0) -eq 0xC0) {
            $pos += 2
            break
        }
        $pos += $Response[$pos] + 1
    }
    if ($Response[$pos] -eq 0) { $pos++ }
    $pos += 4  # Skip QTYPE and QCLASS
    
    # Parse answers
    $ips = @()
    for ($i = 0; $i -lt $answerCount -and $pos -lt $Response.Length - 10; $i++) {
        # Skip name (handle compression)
        if (($Response[$pos] -band 0xC0) -eq 0xC0) {
            $pos += 2
        } else {
            while ($pos -lt $Response.Length -and $Response[$pos] -ne 0) {
                $pos += $Response[$pos] + 1
            }
            $pos++
        }
        
        if ($pos + 10 -gt $Response.Length) { break }
        
        $type = ($Response[$pos] -shl 8) + $Response[$pos + 1]
        $rdLength = ($Response[$pos + 8] -shl 8) + $Response[$pos + 9]
        $pos += 10
        
        # Type A = 1, rdLength = 4
        if ($type -eq 1 -and $rdLength -eq 4 -and $pos + 4 -le $Response.Length) {
            $ip = "$($Response[$pos]).$($Response[$pos+1]).$($Response[$pos+2]).$($Response[$pos+3])"
            $ips += $ip
        }
        
        $pos += $rdLength
    }
    
    if ($ips.Count -gt 0) { return $ips[0] }
    return $null
}

function Invoke-ParallelDnsTest-PS7 {
    param(
        [string[]]$Servers,
        [string]$Domain,
        [int]$TimeoutSeconds,
        [int]$Workers,
        [string]$OutputFilePath
    )
    
    $total = $Servers.Count
    $results = [System.Collections.Concurrent.ConcurrentBag[PSObject]]::new()
    $fileLock = [System.Object]::new()
    
    $Servers | ForEach-Object -Parallel {
        $server = $_
        $domain = $using:Domain
        $timeoutMs = $using:TimeoutSeconds * 1000
        $outputFile = $using:OutputFilePath
        $results = $using:results
        $lock = $using:fileLock
        
        $result = @{
            Server = $server
            Success = $false
            ResponseTime = 0
            ResolvedIP = $null
            Error = $null
        }
        
        $udpClient = $null
        
        try {
            # Build DNS query packet inline (can't call functions from parallel block)
            $id = [byte[]]@((Get-Random -Maximum 256), (Get-Random -Maximum 256))
            $flags = [byte[]]@(0x01, 0x00)
            $counts = [byte[]]@(0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)
            
            $domainBytes = [System.Collections.Generic.List[byte]]::new()
            foreach ($label in $domain.Split('.')) {
                $domainBytes.Add([byte]$label.Length)
                $domainBytes.AddRange([System.Text.Encoding]::ASCII.GetBytes($label))
            }
            $domainBytes.Add(0x00)
            
            $queryType = [byte[]]@(0x00, 0x01, 0x00, 0x01)
            
            $query = [System.Collections.Generic.List[byte]]::new()
            $query.AddRange($id)
            $query.AddRange($flags)
            $query.AddRange($counts)
            $query.AddRange($domainBytes)
            $query.AddRange($queryType)
            $packet = $query.ToArray()
            
            # Send UDP query
            $udpClient = [System.Net.Sockets.UdpClient]::new()
            $udpClient.Client.ReceiveTimeout = $timeoutMs
            $udpClient.Client.SendTimeout = $timeoutMs
            
            $endpoint = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse($server), 53)
            
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            [void]$udpClient.Send($packet, $packet.Length, $endpoint)
            
            $remoteEp = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
            $response = $udpClient.Receive([ref]$remoteEp)
            $stopwatch.Stop()
            
            # Parse response inline
            if ($response.Length -ge 12) {
                if ($response[0] -eq $id[0] -and $response[1] -eq $id[1]) {
                    $rcode = $response[3] -band 0x0F
                    $answerCount = ($response[6] -shl 8) + $response[7]
                    
                    if ($rcode -eq 0 -and $answerCount -gt 0) {
                        # Skip to answers
                        $pos = 12
                        while ($pos -lt $response.Length -and $response[$pos] -ne 0) {
                            if (($response[$pos] -band 0xC0) -eq 0xC0) { $pos += 2; break }
                            $pos += $response[$pos] + 1
                        }
                        if ($pos -lt $response.Length -and $response[$pos] -eq 0) { $pos++ }
                        $pos += 4
                        
                        # Parse first answer
                        if (($response[$pos] -band 0xC0) -eq 0xC0) { $pos += 2 }
                        else {
                            while ($pos -lt $response.Length -and $response[$pos] -ne 0) { $pos += $response[$pos] + 1 }
                            $pos++
                        }
                        
                        if ($pos + 10 -le $response.Length) {
                            $type = ($response[$pos] -shl 8) + $response[$pos + 1]
                            $rdLength = ($response[$pos + 8] -shl 8) + $response[$pos + 9]
                            $pos += 10
                            
                            if ($type -eq 1 -and $rdLength -eq 4 -and $pos + 4 -le $response.Length) {
                                $result.Success = $true
                                $result.ResolvedIP = "$($response[$pos]).$($response[$pos+1]).$($response[$pos+2]).$($response[$pos+3])"
                                $result.ResponseTime = [math]::Round($stopwatch.ElapsedMilliseconds)
                                
                                $line = "$server ($($result.ResponseTime)ms)"
                                [System.Threading.Monitor]::Enter($lock)
                                try { Add-Content -Path $outputFile -Value $line -Encoding UTF8 }
                                finally { [System.Threading.Monitor]::Exit($lock) }
                            }
                        }
                    }
                    else {
                        $result.Error = "RCODE: $rcode"
                    }
                }
            }
            
            if (-not $result.Success -and -not $result.Error) {
                $result.Error = "No answer"
            }
        }
        catch [System.Net.Sockets.SocketException] {
            $result.Error = "Timeout"
        }
        catch {
            $errMsg = $_.Exception.Message
            if ($errMsg.Length -gt 30) { $errMsg = $errMsg.Substring(0, 30) + "..." }
            $result.Error = $errMsg
        }
        finally {
            if ($udpClient) { $udpClient.Close() }
        }
        
        $results.Add([PSCustomObject]$result)
        
        # Print result with color
        $done = $results.Count
        $pct = [math]::Round(($done / $using:total) * 100, 1)
        $progressInfo = "[$done/$($using:total) $pct%]"
        
        if ($result.Success) {
            Write-Host "`r$progressInfo " -NoNewline
            Write-Host "OK " -ForegroundColor Green -NoNewline
            Write-Host "$server $($result.ResponseTime)ms ($($result.ResolvedIP))"
        }
        else {
            $errInfo = if ($result.Error) { $result.Error } else { "timeout/error" }
            Write-Host "`r$progressInfo " -NoNewline
            Write-Host "FAIL " -ForegroundColor Red -NoNewline
            Write-Host "$server ($errInfo)"
        }
        
    } -ThrottleLimit $Workers
    
    return $results.ToArray()
}

function Invoke-ParallelDnsTest-PS5 {
    param(
        [string[]]$Servers,
        [string]$Domain,
        [int]$TimeoutSeconds,
        [int]$Workers,
        [string]$OutputFilePath
    )
    
    # Create runspace pool
    $runspacePool = [runspacefactory]::CreateRunspacePool(1, $Workers)
    $runspacePool.Open()
    
    $jobs = @()
    $results = [System.Collections.Concurrent.ConcurrentBag[PSObject]]::new()
    
    $scriptBlock = {
        param($Server, $Domain, $TimeoutMs, $OutputFilePath)
        
        $result = @{
            Server = $Server
            Success = $false
            ResponseTime = 0
            ResolvedIP = $null
            Error = $null
        }
        
        $udpClient = $null
        
        try {
            # Build DNS query packet
            $id = [byte[]]@((Get-Random -Maximum 256), (Get-Random -Maximum 256))
            $flags = [byte[]]@(0x01, 0x00)
            $counts = [byte[]]@(0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)
            
            $domainBytes = [System.Collections.Generic.List[byte]]::new()
            foreach ($label in $Domain.Split('.')) {
                $domainBytes.Add([byte]$label.Length)
                $domainBytes.AddRange([System.Text.Encoding]::ASCII.GetBytes($label))
            }
            $domainBytes.Add(0x00)
            
            $queryType = [byte[]]@(0x00, 0x01, 0x00, 0x01)
            
            $query = [System.Collections.Generic.List[byte]]::new()
            $query.AddRange($id)
            $query.AddRange($flags)
            $query.AddRange($counts)
            $query.AddRange($domainBytes)
            $query.AddRange($queryType)
            $packet = $query.ToArray()
            
            # Send UDP query
            $udpClient = [System.Net.Sockets.UdpClient]::new()
            $udpClient.Client.ReceiveTimeout = $TimeoutMs
            $udpClient.Client.SendTimeout = $TimeoutMs
            
            $endpoint = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse($Server), 53)
            
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            [void]$udpClient.Send($packet, $packet.Length, $endpoint)
            
            $remoteEp = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
            $response = $udpClient.Receive([ref]$remoteEp)
            $stopwatch.Stop()
            
            # Parse response
            if ($response.Length -ge 12) {
                if ($response[0] -eq $id[0] -and $response[1] -eq $id[1]) {
                    $rcode = $response[3] -band 0x0F
                    $answerCount = ($response[6] -shl 8) + $response[7]
                    
                    if ($rcode -eq 0 -and $answerCount -gt 0) {
                        # Skip to answers
                        $pos = 12
                        while ($pos -lt $response.Length -and $response[$pos] -ne 0) {
                            if (($response[$pos] -band 0xC0) -eq 0xC0) { $pos += 2; break }
                            $pos += $response[$pos] + 1
                        }
                        if ($pos -lt $response.Length -and $response[$pos] -eq 0) { $pos++ }
                        $pos += 4
                        
                        # Parse first answer
                        if (($response[$pos] -band 0xC0) -eq 0xC0) { $pos += 2 }
                        else {
                            while ($pos -lt $response.Length -and $response[$pos] -ne 0) { $pos += $response[$pos] + 1 }
                            $pos++
                        }
                        
                        if ($pos + 10 -le $response.Length) {
                            $type = ($response[$pos] -shl 8) + $response[$pos + 1]
                            $rdLength = ($response[$pos + 8] -shl 8) + $response[$pos + 9]
                            $pos += 10
                            
                            if ($type -eq 1 -and $rdLength -eq 4 -and $pos + 4 -le $response.Length) {
                                $result.Success = $true
                                $result.ResolvedIP = "$($response[$pos]).$($response[$pos+1]).$($response[$pos+2]).$($response[$pos+3])"
                                $result.ResponseTime = [math]::Round($stopwatch.ElapsedMilliseconds)
                                
                                $line = "$Server ($($result.ResponseTime)ms)"
                                $mutex = [System.Threading.Mutex]::new($false, "Global\AzadiDNSTesterFileLock")
                                $mutex.WaitOne() | Out-Null
                                try { [System.IO.File]::AppendAllText($OutputFilePath, "$line`r`n") }
                                finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
                            }
                        }
                    }
                    else {
                        $result.Error = "RCODE: $rcode"
                    }
                }
            }
            
            if (-not $result.Success -and -not $result.Error) {
                $result.Error = "No answer"
            }
        }
        catch [System.Net.Sockets.SocketException] {
            $result.Error = "Timeout"
        }
        catch {
            $errMsg = $_.Exception.Message
            if ($errMsg.Length -gt 30) { $errMsg = $errMsg.Substring(0, 30) + "..." }
            $result.Error = $errMsg
        }
        finally {
            if ($udpClient) { $udpClient.Close() }
        }
        
        return [PSCustomObject]$result
    }
    
    # Throttled job creation
    $total = $Servers.Count
    $allResults = @()
    $completed = 0
    $index = 0
    $timeoutMs = $TimeoutSeconds * 1000

    function Start-OneJob {
        param([string]$Server)
        $powershell = [powershell]::Create().AddScript($scriptBlock)
        $powershell.AddArgument($Server)
        $powershell.AddArgument($Domain)
        $powershell.AddArgument($timeoutMs)
        $powershell.AddArgument($OutputFilePath)
        $powershell.RunspacePool = $runspacePool
        return @{
            PowerShell = $powershell
            Handle = $powershell.BeginInvoke()
        }
    }

    # Prime initial batch
    while ($jobs.Count -lt $Workers -and $index -lt $total) {
        $jobs += Start-OneJob -Server $Servers[$index]
        $index++
    }

    while ($jobs.Count -gt 0) {
        $finishedJobs = @()

        foreach ($job in $jobs) {
            if ($job.Handle.IsCompleted) {
                $result = $job.PowerShell.EndInvoke($job.Handle)
                $allResults += $result
                $job.PowerShell.Dispose()
                $finishedJobs += $job
                $completed++

                # Print result with color
                $pct = if ($total -gt 0) { [math]::Round(($completed / $total) * 100, 1) } else { 100 }
                $progressInfo = "[$completed/$total $pct%]"
                
                if ($result.Success) {
                    Write-Host "$progressInfo " -NoNewline
                    Write-Host "OK " -ForegroundColor Green -NoNewline
                    Write-Host "$($result.Server) $($result.ResponseTime)ms ($($result.ResolvedIP))"
                }
                else {
                    $errInfo = if ($result.Error) { $result.Error } else { "timeout/error" }
                    Write-Host "$progressInfo " -NoNewline
                    Write-Host "FAIL " -ForegroundColor Red -NoNewline
                    Write-Host "$($result.Server) ($errInfo)"
                }

                if ($index -lt $total) {
                    $jobs += Start-OneJob -Server $Servers[$index]
                    $index++
                }
            }
        }

        foreach ($finished in $finishedJobs) {
            $jobs = $jobs | Where-Object { $_ -ne $finished }
        }

        if ($jobs.Count -gt 0) {
            Start-Sleep -Milliseconds 50
        }
    }
    $runspacePool.Close()
    $runspacePool.Dispose()
    
    return $allResults
}

# ==============================================================================
# Main Function
# ==============================================================================

function Main {
    Write-Host "Azadi DNS Tester (PowerShell Edition)"
    Write-Host "======================================================================"
    
    # Detect PowerShell version
    $psVersion = $PSVersionTable.PSVersion.Major
    Write-ColorOutput "PowerShell Version: $($PSVersionTable.PSVersion)" -Color Cyan
    
    if ($psVersion -ge 7) {
        Write-ColorOutput "Parallel Mode: ForEach-Object -Parallel (PS7+)" -Color Cyan
    }
    else {
        Write-ColorOutput "Parallel Mode: Runspace Pool (PS5.1 compatible)" -Color Cyan
    }
    
    # Tool info (using raw UDP for accurate timing)
    Write-ColorOutput "DNS Tool: Raw UDP (port 53)" -Color Cyan
    
    # Load servers
    Write-Host ""
    Write-ColorOutput "Input file: $InputFile" -Color Cyan
    try {
        if (Test-Path $InputFile) {
            $size = (Get-Item -LiteralPath $InputFile).Length
            Write-ColorOutput ("Input size: {0:N0} bytes" -f $size) -Color Cyan
        }
    }
    catch {
        # Ignore size errors (e.g., permission issues)
    }

    if (-not (Test-Path $InputFile)) {
        Write-Host "$InputFile not found. Creating sample file..."
        New-SampleFile -FilePath $InputFile
    }
    
    # Extract unique IPs
    Write-Host "Reading and extracting IPv4 addresses... (this can take a bit for large files)"
    $ipData = Get-IPv4Addresses -FilePath $InputFile
    $servers = $ipData.UniqueIPs
    
    if ($servers.Count -eq 0) {
        Write-ColorOutput "No valid IPv4 addresses found in $InputFile" -Color Red
        exit 1
    }
    
    Write-Host "Extracted $($ipData.UniqueCount) UNIQUE IPv4 addresses from $InputFile"
    Write-Host "Total IPs found (with duplicates): $($ipData.TotalCount)"
    Write-Host "UNIQUE IPs: $($ipData.UniqueCount)"
    
    # Get configuration (interactive or from parameters)
    if ($NonInteractive) {
        $workerCount = if ($Workers -gt 0) { $Workers } else { $DEFAULT_WORKERS }
        $timeoutValue = if ($Timeout -gt 0) { $Timeout } else { $DEFAULT_TIMEOUT }
        $testDomain = if ($Domain) { $Domain } else { $DEFAULT_DOMAIN }
    }
    else {
        $workerCount = Get-WorkerCount
        $timeoutValue = Get-TimeoutValue
        $testDomain = Get-TestDomain
    }
    
    # Write header
    Write-OutputHeader -FilePath $OutputFile -Domain $testDomain
    
    Write-Host ""
    Write-Host "Starting test of $($servers.Count) DNS servers"
    Write-Host "Config: Workers=$workerCount | Timeout=${timeoutValue}s | Domain=$testDomain"
    Write-Host "Working servers will be SAVED IMMEDIATELY as found!"
    Write-Host "----------------------------------------------------------------------"
    
    $startTime = Get-Date
    
    Write-Host "Testing servers..."
    
    # Run parallel tests based on PS version
    if ($psVersion -ge 7) {
        $results = Invoke-ParallelDnsTest-PS7 -Servers $servers -Domain $testDomain -TimeoutSeconds $timeoutValue -Workers $workerCount -OutputFilePath $OutputFile
    }
    else {
        $results = Invoke-ParallelDnsTest-PS5 -Servers $servers -Domain $testDomain -TimeoutSeconds $timeoutValue -Workers $workerCount -OutputFilePath $OutputFile
    }
    
    $endTime = Get-Date
    $elapsed = [math]::Round(($endTime - $startTime).TotalSeconds, 1)
    
    # Process results
    $working = @($results | Where-Object { $_.Success })
    $failed = @($results | Where-Object { -not $_.Success })
    
    # Calculate statistics
    $successRate = if ($servers.Count -gt 0) { [math]::Round(($working.Count / $servers.Count) * 100, 1) } else { 0 }
    
    # Print summary
    Write-Host ""
    Write-Host "======================================================================"
    Write-Host "DNS SERVER TEST RESULTS"
    Write-Host "======================================================================"
    Write-Host "Total servers tested: $($servers.Count)"
    Write-Host "Working servers:      $($working.Count) ($successRate%)"
    Write-Host "Failed servers:       $($failed.Count)"
    Write-Host "Test duration:        $elapsed seconds"
    Write-Host "Test domain:          $testDomain"
    Write-Host ""
    
    if ($working.Count -gt 0) {
        Write-Host "TOP 5 FASTEST SERVERS:"
        $topServers = $working | Sort-Object ResponseTime | Select-Object -First 5
        $rank = 1
        foreach ($srv in $topServers) {
            Write-Host ("  {0}. {1,-15} {2}ms" -f $rank, $srv.Server, $srv.ResponseTime)
            $rank++
        }
        if ($working.Count -gt 5) {
            Write-Host "  ... $($working.Count - 5) more servers"
        }
        Write-Host ""
    }
    
    Write-Host "Results saved: $OutputFile ($($working.Count) servers)"
    Write-Host "======================================================================"
    Write-Host ""
    Write-Host "Testing complete!"
}

# Run main function
Main
