# =============================================================================
# Stage 5 Test Script — Reminder Scheduler smoke tests
# =============================================================================
#
# Tests the Reminder Scheduler workflow via its TEST URL (workflow not yet
# published). Run each test individually by pasting the relevant block.
#
# Before running:
#   1. In n8n, open the "Reminder Scheduler" workflow.
#   2. Click the "Webhook: Reminder Schedule" node.
#   3. Click "Listen for test event" (top of the right panel).
#      The webhook is now armed for 120 seconds.
#   4. Run ONE test below — within those 120 seconds.
#   5. Watch the canvas: nodes light up as data flows through them.
#   6. To run the next test, click "Listen for test event" again.
#
# After each test, run the verification SQL in psql to confirm DB state.
# =============================================================================

# -----------------------------------------------------------------------------
# CONFIG — set these once per session
# -----------------------------------------------------------------------------
$WebhookSecret = "zpxL8aaYoLVmAH6lHNaXalst/yATYDhpqsxJicl0kE4="
$TestPhone     = "+61447544217"
$TestUrl       = "https://n8n.synthella.com.au/webhook/reminder-schedule"

# Sanity check — refuses to run if you forgot to paste the secret.
if ($WebhookSecret -eq "PASTE_YOUR_REMINDER_SCHEDULER_SECRET_HERE") {
    Write-Host "ERROR: Set `$WebhookSecret first." -ForegroundColor Red
    return
}

# Helper — generate a unique appointment_id for each test run
function New-ApptId {
    return "test_appt_$(Get-Date -Format 'yyyyMMddHHmmss')_$([System.Guid]::NewGuid().ToString().Substring(0,8))"
}

# Helper — ISO 8601 timestamp N minutes from now, in local timezone with offset
function Get-AppointmentStart {
    param([int]$MinutesFromNow)
    return (Get-Date).AddMinutes($MinutesFromNow).ToString("yyyy-MM-ddTHH:mm:ssK")
}

# Helper — POST to the webhook
function Invoke-ReminderTest {
    param(
        [Parameter(Mandatory)] [hashtable]$Body,
        [string]$Description = "test"
    )
    Write-Host "`n=== $Description ===" -ForegroundColor Cyan
    Write-Host "POST $TestUrl"
    Write-Host "Payload:"
    $Body | ConvertTo-Json -Depth 10 | Write-Host

    try {
        $resp = Invoke-RestMethod `
            -Uri $TestUrl `
            -Method POST `
            -Headers @{ "x-webhook-secret" = $WebhookSecret } `
            -ContentType "application/json" `
            -Body ($Body | ConvertTo-Json -Depth 10) `
            -ErrorAction Stop
        Write-Host "`nResponse (success):" -ForegroundColor Green
        $resp | ConvertTo-Json -Depth 10 | Write-Host
        return $resp
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        Write-Host "`nResponse (HTTP $statusCode):" -ForegroundColor Yellow
        if ($_.ErrorDetails.Message) {
            Write-Host $_.ErrorDetails.Message
        } else {
            Write-Host $_.Exception.Message
        }
        return $null
    }
}


# =============================================================================
# TEST 1 — Validation failure (missing required field)
# =============================================================================
# Expected: HTTP 400, error: "missing_required_fields", missing: ["body"]
# Expected DB state: NO new rows in messages or contact_contexts
# Expected canvas: webhook → Validate → If: Valid? (false branch) → Respond: Validation Error
#
# Before running: arm the webhook (click "Listen for test event")

# Uncomment to run T1:
<#
$T1 = Invoke-ReminderTest -Description "T1: Validation failure (missing body)" -Body @{
    appointment_id    = New-ApptId
    phone             = $TestPhone
    appointment_start = Get-AppointmentStart -MinutesFromNow 30
    first_name        = "Test"
    # body intentionally omitted
}
#>



# =============================================================================
# TEST 2 — Happy path, IMMEDIATE mode
# =============================================================================
# Appointment 16 min from now → reminder time = -4 min from now → "immediate" mode.
# Expected: HTTP 200, mode: "immediate", twilio_status: queued/accepted/sent
# Expected DB:
#   messages: 1 new row, message_type='reminder', source='reminder',
#             twilio_sid populated, twilio_message_sid populated (dual write),
#             sent_at populated (immediate mode), appointment_id matches
#   contact_contexts: 1 new row, context_type='reminder', priority=300,
#                     anchor_outbound_message_id matches the message id,
#                     expires_at = appointment_start + 2h
#   contacts: last_outbound_at updated
# Expected SMS: arrives on $TestPhone within ~30 seconds
# Expected status callback: fires within ~1 minute, populates delivered_at
#
# Before running: arm the webhook again (click "Listen for test event")

# Uncomment to run T2 (saves the appointment_id for use in T3):

$T2_ApptId = New-ApptId
$T2 = Invoke-ReminderTest -Description "T2: Happy path (immediate mode)" -Body @{
    appointment_id    = $T2_ApptId
    phone             = $TestPhone
    appointment_start = Get-AppointmentStart -MinutesFromNow 16
    first_name        = "Test"
    body              = "Stage 5 test reminder. Reply C to confirm. Sent at $(Get-Date -Format 'HH:mm:ss')."
}
Write-Host "`nSaved appointment_id for T3: $T2_ApptId" -ForegroundColor Magenta



# =============================================================================
# TEST 3 — Idempotency
# =============================================================================
# Replay T2's appointment_id. The Idempotency Check should find the existing
# row and short-circuit before the Twilio call.
# Expected: HTTP 200, idempotent: true, twilio_sid matches T2's response
# Expected DB: NO new rows. Same single message and context as T2.
# Expected SMS: NO additional SMS sent.
# Expected canvas: stops at Respond: Idempotent (does NOT reach Twilio: Send Reminder)
#
# Before running: arm the webhook again. T2 must have run first.

# Uncomment to run T3:

$T3 = Invoke-ReminderTest -Description "T3: Idempotency replay" -Body @{
    appointment_id    = $T2_ApptId
    phone             = $TestPhone
    appointment_start = Get-AppointmentStart -MinutesFromNow 16
    first_name        = "Test"
    body              = "This body should be ignored - idempotent hit."
}



# =============================================================================
# QUICK VERIFICATION QUERIES (run in psql between tests)
# =============================================================================
#
# After T2 — confirm row inserts:
#
#   SELECT id, contact_id, direction, source, message_type, twilio_status,
#          twilio_sid, appointment_id, sent_at, created_at
#     FROM messages
#    WHERE message_type = 'reminder'
#    ORDER BY created_at DESC
#    LIMIT 5;
#
#   SELECT id, contact_id, context_type, context_status, priority,
#          appointment_id, anchor_outbound_message_id, opened_at, expires_at
#     FROM contact_contexts
#    WHERE context_type = 'reminder'
#    ORDER BY opened_at DESC
#    LIMIT 5;
#
# After T2 + ~1 minute — confirm status callback fired:
#
#   SELECT m.id, m.twilio_status, m.sent_at, m.delivered_at, m.failed_at,
#          (SELECT COUNT(*) FROM message_status_events
#            WHERE twilio_message_sid = m.twilio_sid) AS event_count
#     FROM messages m
#    WHERE m.message_type = 'reminder'
#    ORDER BY m.created_at DESC
#    LIMIT 1;
#
# After T3 — confirm NO duplicate row:
#
#   SELECT COUNT(*) AS reminder_count_for_appt
#     FROM messages
#    WHERE appointment_id = '<T2_appointment_id_here>';
#   -- Must return exactly 1.
#
# =============================================================================