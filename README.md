# homeconnect-oven-matter

Matter bridge service for a HomeConnect oven using `homeconnect_local` over TLS-PSK.

The service is non-interactive and binds Matter UDP on an ephemeral port (`port: 0`).
When uncommissioned, it prints the Matter QR code and setup PIN to stdout.

![Image](https://github.com/user-attachments/assets/3a7d6920-2d43-4676-bd52-758723f34a47)

## Endpoints

1. `endpoint 1` microwave slider: `OnOff + LevelControl` (`0..100%` -> `1..100s`)
1. `endpoint 2` preheat slider: `LevelControl` (`0..100%` -> `100..200°C`)
1. `endpoint 3` cavity temperature sensor: `TemperatureMeasurement`
1. `endpoint 4` door contact sensor: `BooleanState`
1. `endpoint 5` operation-state contact sensor: `BooleanState`
1. `endpoint 6` power button endpoint: `OnOff`
1. `endpoint 7` pause/resume button endpoint: `OnOff`

## Local Run

```bash
crystal run src/homeconnect-oven-matter.cr -- \
  --ip=192.168.4.79 \
  --psk64='gU_uf9kitLaAaisF5C8NIA' \
  --identity=homeconnect \
  --cipher=PSK \
  --device-xml=./certs/039024000094_DeviceDescription.xml \
  --feature-xml=./certs/039024000094_FeatureMapping.xml
```

Environment variables are also supported:

- `HC_OVEN_IP`
- `HC_PSK64`
- `HC_IDENTITY`
- `HC_CIPHER`
- `HC_DEVICE_XML`
- `HC_FEATURE_XML`
- `MATTER_STORAGE_FILE`
- `HC_POLL_INTERVAL`
- `LOG_LEVEL`

For commissioning troubleshooting, set `LOG_LEVEL=debug`.

## Docker

Add the required keys into `.env`

```
HC_OVEN_IP=192.168.4.79
HC_PSK64=gU_Z0uf9kitLaAaisFxUAo5A
HC_DEVICE_XML=24000094_DeviceDescription.xml
HC_FEATURE_XML=24000094_FeatureMapping.xml
```

then

```bash
chmod -R a+rwX ./data
docker compose up
```

`docker-compose.yml` uses `network_mode: host` and mounts:

- `./certs -> /app/certs` (read-only)
- `./data -> /app/data` (needs permissive write permissions)

## Validation

For real oven validation, use read-only status checks first.
Do not send program commands until manual iOS testing.
