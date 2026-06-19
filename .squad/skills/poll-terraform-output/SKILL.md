# Skill: poll-terraform-output

Poll a `terraform output -raw <name>` until it returns a non-empty value, with a configurable interval and timeout. Useful immediately after `terraform apply` when a cloud resource (GCP VLAN attachment, Azure ER circuit, etc.) is still provisioning and its output value is not yet populated in state.

## When to use

- You need a Terraform output value that is set by a resource that provisions asynchronously (e.g. `google_compute_interconnect_attachment.pairing_key`, Azure ER `service_key`).
- You want to display the value to the user before they take a manual step (e.g. paste into a provider portal).
- You need to support both interactive and unattended (`-AutoApprove` / CI) runs without blocking indefinitely.

## PowerShell pattern

```powershell
# Tunables — place near the script's constants block.
$KeyPollIntervalSec = 30     # seconds between retries
$KeyPollTimeoutSec  = 1800   # overall cap (30 min)

$capturedValue = ''
$pollStart     = [System.Diagnostics.Stopwatch]::StartNew()

while ([string]::IsNullOrWhiteSpace($capturedValue)) {
    $v = (& terraform -chdir=$TfDir output -raw my_output_name 2>$null)
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($v)) {
        $capturedValue = $v
        break
    }

    $elapsed = [int]$pollStart.Elapsed.TotalSeconds
    if ($elapsed -ge $KeyPollTimeoutSec) {
        Write-Warn "Timed out waiting for 'my_output_name' after ${elapsed}s."
        break
    }

    Write-Host "  [${elapsed}s]  Still waiting for my_output_name ..." -ForegroundColor Yellow
    Start-Sleep -Seconds $KeyPollIntervalSec
}

if (-not [string]::IsNullOrWhiteSpace($capturedValue)) {
    Write-Host "  my_output_name: $capturedValue" -ForegroundColor Cyan
} else {
    Write-Warn "my_output_name not available."
}
```

## Bash pattern

```bash
# Tunables — place in the readonly constants block.
readonly KEY_POLL_INTERVAL=30
readonly KEY_POLL_TIMEOUT=1800

CAPTURED_VALUE=""
POLL_START="$(date +%s)"

while [[ -z "${CAPTURED_VALUE}" ]]; do
  _v="$(terraform -chdir="${TF_DIR}" output -raw my_output_name 2>/dev/null || true)"
  if [[ -n "${_v}" ]]; then
    CAPTURED_VALUE="${_v}"
    break
  fi

  ELAPSED=$(( $(date +%s) - POLL_START ))
  if (( ELAPSED >= KEY_POLL_TIMEOUT )); then
    warn "Timed out waiting for 'my_output_name' after ${ELAPSED}s."
    break
  fi

  printf "${YLW}  [%ds]  Still waiting for my_output_name ...${NC}\n" "${ELAPSED}"
  sleep "${KEY_POLL_INTERVAL}"
done

if [[ -n "${CAPTURED_VALUE}" ]]; then
  printf "${CYN}  my_output_name: %s${NC}\n" "${CAPTURED_VALUE}"
else
  warn "my_output_name not available."
fi
```

## Polling multiple outputs independently

When waiting for N outputs simultaneously (e.g. GCP pairing key + Azure service key), track each in its own variable and skip re-polling once captured:

```bash
while true; do
  [[ -z "${KEY1}" ]] && KEY1="$(terraform -chdir="${DIR1}" output -raw out1 2>/dev/null || true)"
  [[ -z "${KEY2}" ]] && KEY2="$(terraform -chdir="${DIR2}" output -raw out2 2>/dev/null || true)"
  [[ -n "${KEY1}" && -n "${KEY2}" ]] && break
  # ... timeout check and sleep ...
done
```

## Known usage

- `scripts/deploy.ps1` and `scripts/deploy.sh` — Step 4c of `Invoke-ExpressRoute` / `run_expressroute`: polls `interconnect_pairing_key` (GCP) and `expressroute_service_key` (Azure) until both are ready before displaying them for the Megaport VXC provisioning step.

## Notes

- `terraform output -raw` exits non-zero if the output does not exist in state OR is null/empty. The non-zero exit is the reliable "not ready yet" signal.
- Both outputs are `sensitive = true`; `-raw` still prints them verbatim — no redaction for shell capture.
- Ctrl-C exits cleanly under `set -euo pipefail` (bash) and `$ErrorActionPreference = Stop` (PS).
- Interval 30 s and timeout 1 800 s are project defaults. Adjust for faster or slower providers.
