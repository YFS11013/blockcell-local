# EA Scripts

## 1) Copy EA Files To MT4

```powershell
pwsh -NoProfile -File "domain_experts/forex/ea/scripts/copy_to_mt4.ps1"
```

## 2) Batch Generate Historical Signal Packs

Script: `generate_historical_signal_packs.py`

### Dry-run preview (no file writes)

```powershell
python domain_experts/forex/ea/scripts/generate_historical_signal_packs.py --months 6 --dry-run
```

### Generate latest 6 months (daily)

```powershell
python domain_experts/forex/ea/scripts/generate_historical_signal_packs.py --months 6 --write-index
```

### Generate latest 12 months (daily, overwrite existing)

```powershell
python domain_experts/forex/ea/scripts/generate_historical_signal_packs.py --months 12 --overwrite --write-index
```

### Generate a fixed date range

```powershell
python domain_experts/forex/ea/scripts/generate_historical_signal_packs.py --start-date 2025-01-01 --end-date 2025-12-31 --write-index
```

### Output location

Default output directory:

`domain_experts/forex/ea/history/signal_packs/`

Generated file name pattern (default):

`signal_pack_{version}.json`

You can customize it:

```powershell
python domain_experts/forex/ea/scripts/generate_historical_signal_packs.py --months 6 --filename-pattern "pack_{date}_{version}.json"
```

