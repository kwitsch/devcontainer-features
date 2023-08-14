
# Shared Package Cache (shared-package-cache)

Shares package caches between devcontainers

## Example Usage

```json
"features": {
    "ghcr.io/kwitsch/devcontainer-features/shared-package-cache:0": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|
| go | Golang use the shared package cache volume | boolean | true |
| npm | NPM use the shared package cache volume | boolean | true |
| cachedir | The cache folder should point to a volume that is shared among different devcontainers | string | /var/package-cache |



---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/kwitsch/devcontainer-features/blob/main/src/shared-package-cache/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
