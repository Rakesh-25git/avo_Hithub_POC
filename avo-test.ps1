# ============================================================
# Avo Assure execution script for CI/CD
# ============================================================

# Ignore SSL/TLS validation (for testing purposes only)
# Branches based on PowerShell edition: Core (pwsh, e.g. Linux agents or Windows+pwsh)
# vs Desktop (Windows PowerShell 5.1, e.g. classic Windows agents)
if ($PSVersionTable.PSEdition -eq 'Core') {
    $PSDefaultParameterValues = @{
        'Invoke-RestMethod:SkipCertificateCheck' = $true
    }
}
else {
    if (-not ([System.Management.Automation.PSTypeName]'ServerCertificateValidationCallback').Type) {
        $certCallback = @"
            using System;
            using System.Net;
            using System.Net.Security;
            using System.Security.Cryptography.X509Certificates;
            public class ServerCertificateValidationCallback {
                public static void Ignore() {
                    if(ServicePointManager.ServerCertificateValidationCallback == null) {
                        ServicePointManager.ServerCertificateValidationCallback +=
                            delegate(Object obj, X509Certificate certificate, X509Chain chain, SslPolicyErrors errors) {
                                return true;
                            };
                    }
                }
            }
"@
        Add-Type $certCallback
    }
    [ServerCertificateValidationCallback]::Ignore()
}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12


# ------------------------------------------------------------
# Execution key comes from the GitHub Actions secret
# ------------------------------------------------------------

$executionKey = $env:AVO_EXECUTION_KEY

if ([string]::IsNullOrWhiteSpace($executionKey)) {
    Write-Host -f red "AVO_EXECUTION_KEY secret is not set."
    exit 1
}

# Stops the key from ever appearing in a GitHub log
if ($env:GITHUB_ACTIONS -eq "true") {
    Write-Host "::add-mask::$executionKey"
}


# Define headers and body
$headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
$headers.Add("Content-Type", "application/json")

$body = @{
    key           = $executionKey
    executionType = "asynchronous"
} | ConvertTo-Json


try {
    $response = Invoke-RestMethod 'https://avoqa.avoassurecloud.com/execAutomation' -Method 'POST' -Headers $headers -Body $body
    $status = $response.status

    # Check if status is pass or fail
    if ($status -ne "fail") {
        Write-Host "Status            :" $response.status
        Write-Host "ReportLink        :" $response.reportLink
        Write-Host "RunningStatusLink :" $response.runningStatusLink

        $runningStatusLink = $response.runningStatusLink

        $statusResponse = Invoke-RestMethod -Uri $runningStatusLink -Method 'GET' -Headers $headers
        $runningStatus  = $statusResponse.status
        $complete       = $statusResponse.Completed

        while ($runningStatus -eq "Inprogress") {
            Write-Host "Executing... $complete"

            $statusResponse = Invoke-RestMethod -Uri $runningStatusLink -Method 'GET' -Headers $headers
            $runningStatus  = $statusResponse.status

            if ($statusResponse.PSObject.Properties["Completed"]) {
                $complete = $statusResponse.Completed
            }
            else {
                $complete = ""
            }
            Start-Sleep -Seconds 5
        }

        if ($runningStatus -eq "Completed") {
            $summaryReport = $statusResponse | ConvertTo-Json -Depth 10
            Write-Host $summaryReport

            $overallstatus = $statusResponse.overallstatus
            Write-Host $overallstatus

            # ------------------------------------------------
            # Quality gate - makes the pipeline red on failure
            # ------------------------------------------------
            if ($overallstatus -eq "Pass") {
                Write-Host "Avo Assure execution PASSED."
                exit 0
            }
            else {
                Write-Host -f red "Avo Assure execution FAILED. Overall status: $overallstatus"
                exit 1
            }
        }
        else {
            Write-Host -f red "Execution ended with unexpected status: $runningStatus"
            exit 1
        }
    }
    else {
        Write-Host "Some error occurred"
        exit 1
    }
}
catch {
    Write-Host -f red "Encountered Error:"$_.Exception.Message
    exit 1
}
