# =============================================================================
# Stage 5 Test Script — Reminder Cancel + Scheduled-Mode tests
# =============================================================================
#
# Runs all 5 tests automatically, prints a summary at the end:
#   C1: Validation failure (missing appointment_id) → 400
#   C2: Cancel non-existent appointment → 404
#   C3a: Schedule reminder 30 min out → 200 with mode='scheduled'
#   C3b: Cancel that reminder → 200
#   C4: Re-cancel already-cancelled → 404
#
# Pre-requisites: Reminder Scheduler + Reminder Cancel workflows active
# =============================================================================

# -----------------------------------------------------------------------------
# CONFIG
# -----------------------------------------------------------------------------
$WebhookSecret = "zpxL8aaYoLVmAH6lHNaXalst/yATYDhpqsxJicl0kE4="
$TestPhone     = "+61447544217"
$ScheduleUrl   = "https://n8n.synthella.com.au/webhook/reminder-schedule"
$CancelUrl     = "https://n8n.synthella.com.au/webhook/reminder-cancel"

if ($WebhookSecret -eq "PASTE_YOUR_REMINDER_SCHEDULER_SECRET_HERE") {
    Write-Host "ERROR: Set `$WebhookSecret first." -ForegroundColor Red
    return
}

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
function New-ApptId {
    return "test_appt_$(Get-Date -Format 'yyyyMMddHHmmss')_$([System.Guid]::NewGuid().ToString().Substring(0,8))"
}

function Get-AppointmentStart {
    param([int]$MinutesFromNow)
    return (Get-Date).AddMinutes($MinutesFromNow).ToString("yyyy-MM-ddTHH:mm:ssK")
}

function Invoke-Webhook {
    param(
        [Parameter(Mandatory)] [string]$Url,
        [Parameter(Mandatory)] [hashtable]$Body,
        [string]$Description = "test",
        [int]$ExpectedStatus = 200
    )
    Write-Host "`n--- $Description ---" -ForegroundColor Cyan
    Write-Host "Payload: $($Body | ConvertTo-Json -Depth 10 -Compress)" -ForegroundColor DarkGray

    $statusCode = 0
    $responseBody = $null

    try {
        $resp = Invoke-RestMethod `
            -Uri $Url `
            -Method POST `
            -Headers @{ "x-webhook-secret" = $WebhookSecret } `
            -ContentType "application/json" `
            -Body ($Body | ConvertTo-Json -Depth 10) `
            -ErrorAction Stop
        $statusCode = 200
        $responseBody = $resp
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        if ($_.ErrorDetails.Message) {
            try { $responseBody = $_.ErrorDetails.Message | ConvertFrom-Json }
            catch { $responseBody = $_.ErrorDetails.Message }
        }
    }

    $passed = ($statusCode -eq $ExpectedStatus)
    $marker = if ($passed) { "PASS" } else { "FAIL" }
    $colour = if ($passed) { "Green" } else { "Red" }

    Write-Host "$marker  HTTP $statusCode (expected $ExpectedStatus)" -ForegroundColor $colour
    Write-Host "Response: $($responseBody | ConvertTo-Json -Depth 10 -Compress)"

    return [pscustomobject]@{
        Passed     = $passed
        StatusCode = $statusCode
        Body       = $responseBody
    }
}

function Show-Banner {
    param([string]$Text)
    Write-Host ""
    Write-Host ("=" * 75) -ForegroundColor Yellow
    Write-Host " $Text" -ForegroundColor Yellow
    Write-Host ("=" * 75) -ForegroundColor Yellow
}


# =============================================================================
# Run all tests
# =============================================================================

$results = @{}

Show-Banner "C1: Cancel without appointment_id (expect 400)"
$results.C1 = Invoke-Webhook `
    -Description "C1" `
    -Url $CancelUrl `
    -Body @{} `
    -ExpectedStatus 400

Show-Banner "C2: Cancel non-existent appointment (expect 404)"
$results.C2 = Invoke-Webhook `
    -Description "C2" `
    -Url $CancelUrl `
    -Body @{ appointment_id = "test_appt_does_not_exist_$(Get-Date -Format 'HHmmss')" } `
    -ExpectedStatus 404

Show-Banner "C3: Schedule reminder 30 min out, then cancel it"
$C3_ApptId = New-ApptId
Write-Host "C3 appointment_id: $C3_ApptId" -ForegroundColor Magenta

$results.C3a = Invoke-Webhook `
    -Description "C3a Schedule" `
    -Url $ScheduleUrl `
    -Body @{
        appointment_id    = $C3_ApptId
        phone             = $TestPhone
        appointment_start = Get-AppointmentStart -MinutesFromNow 40
        first_name        = "Test"
        body              = "C3 SHOULD NEVER ARRIVE - if you see this, cancel failed. Sent at $(Get-Date -Format 'HH:mm:ss')."
    } `
    -ExpectedStatus 200

if ($results.C3a.Passed -and $results.C3a.Body.mode -eq "scheduled") {
    Write-Host "Schedule mode: scheduled" -ForegroundColor Green
    Write-Host "Twilio SID:    $($results.C3a.Body.twilio_sid)" -ForegroundColor Magenta

    Write-Host "`nWaiting 5 seconds..." -ForegroundColor Magenta
    Start-Sleep -Seconds 5

    $results.C3b = Invoke-Webhook `
        -Description "C3b Cancel" `
        -Url $CancelUrl `
        -Body @{ appointment_id = $C3_ApptId } `
        -ExpectedStatus 200
} else {
    if ($results.C3a.Body.mode -ne "scheduled") {
        Write-Host "ERROR: Expected mode='scheduled' but got '$($results.C3a.Body.mode)'." -ForegroundColor Red
        Write-Host "Skipping C3b and C4." -ForegroundColor Red
    }
    $results.C3b = $null
}

if ($results.C3b -and $results.C3b.Passed) {
    Show-Banner "C4: Re-cancel already-cancelled (expect 404)"
    $results.C4 = Invoke-Webhook `
        -Description "C4" `
        -Url $CancelUrl `
        -Body @{ appointment_id = $C3_ApptId } `
        -ExpectedStatus 404
} else {
    Write-Host "`nSkipping C4 (C3b did not pass)." -ForegroundColor Yellow
    $results.C4 = $null
}


# =============================================================================
# Summary
# =============================================================================
Show-Banner "SUMMARY"

$tests = @(
    @{ Name = "C1 (validation 400)";    Result = $results.C1 },
    @{ Name = "C2 (404 not found)";     Result = $results.C2 },
    @{ Name = "C3a (schedule 200)";     Result = $results.C3a },
    @{ Name = "C3b (cancel 200)";       Result = $results.C3b },
    @{ Name = "C4 (re-cancel 404)";     Result = $results.C4 }
)

$allPassed = $true
foreach ($t in $tests) {
    if ($null -eq $t.Result) {
        Write-Host ("  {0,-28} SKIPPED" -f $t.Name) -ForegroundColor Yellow
        $allPassed = $false
    } elseif ($t.Result.Passed) {
        Write-Host ("  {0,-28} PASS (HTTP {1})" -f $t.Name, $t.Result.StatusCode) -ForegroundColor Green
    } else {
        Write-Host ("  {0,-28} FAIL (HTTP {1})" -f $t.Name, $t.Result.StatusCode) -ForegroundColor Red
        $allPassed = $false
    }
}

Write-Host ""
if ($allPassed) {
    Write-Host "ALL TESTS PASSED" -ForegroundColor Green
} else {
    Write-Host "SOME TESTS FAILED OR SKIPPED" -ForegroundColor Red
}

Write-Host ""
Write-Host "Verification SQL (paste into psql):" -ForegroundColor Cyan
Write-Host "  SELECT id, twilio_status, sent_at, failed_at FROM messages WHERE appointment_id = '$C3_ApptId';" -ForegroundColor DarkCyan
Write-Host "  SELECT context_status, resolved_at FROM contact_contexts WHERE appointment_id = '$C3_ApptId';" -ForegroundColor DarkCyan
Write-Host ""
Write-Host "Then wait 25+ minutes - NO SMS should arrive on $TestPhone." -ForegroundColor Magenta
