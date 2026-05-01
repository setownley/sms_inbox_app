@echo off
cd /d "D:\sms_inbox\Versions\sms_inbox_app"
git add .
git commit -m "Stage 4: idempotency gate on inbound webhook"
git push origin main
pause