# ISSUE 01: Invalid base image reference for client build

## Summary

A local startup attempt failed because the client Dockerfile referenced a non-existent OpenSUSE image tag: `opensuse/leap-micro:6.2`.

## Original problem

While following `docs/quickstart.md` and executing `./scripts/start-local.sh`, the Docker build process failed during the client image build.

The failure occurred when Docker attempted to pull the base image used by `client/Dockerfile`:

```dockerfile
FROM opensuse/leap-micro:6.2
```

The error from the build was:

- `pull access denied, repository does not exist or may require authorization`
- `failed to resolve source metadata for docker.io/opensuse/leap-micro:6.2`

## Evidence

The relevant log output included:

```text
WARN[0000] /home/clems/edgekit/docker-compose.yml: the attribute `version` is obsolete, it will be ignored, please remove it to avoid potential confusion
[+] Building 1.4s (7/7) FINISHED
[client internal] load metadata for docker.io/opensuse/leap-micro:6.2 0.8s
...
failed to solve: opensuse/leap-micro:6.2: failed to resolve source metadata for docker.io/opensuse/leap-micro:6.2: pull access denied, repository does not exist or may require authorization
```

## Investigation

1. Verified the Docker image reference in `client/Dockerfile`.
2. Confirmed that `opensuse/leap-micro:6.2` is not available on Docker Hub.
3. Checked the official OpenSUSE image repository listings and found available image families such as `opensuse/leap` and `opensuse/tumbleweed`.
4. Noted that the `docker-compose` file also raised an unrelated warning about the obsolete `version` field.

## Impact

- The client image build cannot start.
- The local environment cannot be launched with `./scripts/start-local.sh`.
- The build pipeline is blocked until the base image reference is corrected.

## Solutions considered

1. Replace the base image with an existing OpenSUSE image such as `opensuse/leap:15.5`.
   - This would restore a valid image, but changes the runtime environment.
2. Find an alternative or alternative registry for `opensuse/leap-micro`.
   - This preserves the intended minimal image but requires a valid source.
3. Build the `leap-micro` image manually from OpenSUSE sources.
   - This is more complex and should be avoided unless necessary.

## Adopted solution

The chosen resolution was to use the official OpenSUSE registry variant and point the client base image to the available `leap-micro:6.1` image.

This solution meets the original intention of keeping a `leap-micro` base image while avoiding the unavailable `6.2` tag.

## Implementation details

- Updated `client/Dockerfile` to use the official registry source:

```dockerfile
FROM registry.opensuse.org/opensuse/leap-micro/6.1/toolbox:latest
```

- This change preserves the `leap-micro` environment and avoids switching to a full `opensuse/leap` image.
- It also ensures the build uses a known available image from the OpenSUSE registry.

## Impact of the fix

- The Docker build can now resolve the client base image.
- Local startup is no longer blocked by the missing image tag.
- The project maintains the lean `leap-micro` runtime environment.
- The previously identified issue with the `docker-compose.yml` `version` field remains a separate cleanup item.

## Notes

- The user environment is running Docker Compose v5.4.2 while the project documentation refers to v2. The Compose version warning is not blocking the build, but it may be worth updating the configuration for compatibility.
- The fix preserves the intended minimal base image rather than replacing it with a different OpenSUSE distribution.
