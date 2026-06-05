# ISSUE 02: Node.js build failure on leap-micro base image

## Summary

The client Docker build failed when using the `opensuse/leap-micro/6.1/toolbox` base image because the expected Node.js packages were not available in the configured repositories.

## Original problem

Running `sudo ./scripts/build.sh` triggered a failure while building the `edgekit-client` image.

The relevant failure occurred in `client/Dockerfile` at the step:

```dockerfile
RUN zypper --non-interactive install --no-recommends nodejs20 npm20
```

The build output showed:

- `No provider of 'nodejs20' found`
- `No provider of 'npm20' found`

A manual diagnostic command confirmed the issue in the base image:

```bash
docker run --rm registry.opensuse.org/opensuse/leap-micro/6.1/toolbox:latest zypper se nodejs
```

This produced:

- `No matching items found.`

## Research and investigation

1. Reviewed the current `client/Dockerfile` content.
2. Confirmed the build base image was `registry.opensuse.org/opensuse/leap-micro/6.1/toolbox:latest`.
3. Verified the package search output inside the image to determine whether Node.js was missing globally or only under specific package names.
4. Identified that the default `leap-micro` repositories are very minimal and do not provide `nodejs` or `npm` packages.

## Solutions considered

1. Use the official Node.js Docker image, such as `node:20-slim`.
   - Pros: simple, reliable, officially maintained.
   - Cons: changes the base OS image and does not preserve `leap-micro`.

2. Add a custom Zypper repository that provides Node.js for `leap-micro`.
   - Pros: could preserve package management with Zypper.
   - Cons: requires finding a compatible OBS repository and may add maintenance risk.

3. Download and install the official Node.js binary tarball directly in the Docker image.
   - Pros: preserves the `leap-micro` base image and avoids relying on unavailable Zypper packages.
   - Cons: adds a manual installation step and relies on the Node.js binary distribution.

## Solutions tested

The chosen path was to implement solution 3: install the official Node.js binary directly.

The new `client/Dockerfile` block became:

```dockerfile
RUN zypper --non-interactive install --no-recommends curl tar gzip xz && \
    curl -fsSL https://nodejs.org/dist/v20.16.0/node-v20.16.0-linux-x64.tar.xz | tar -xJ -C /usr/local --strip-components=1 && \
    zypper clean -a && \
    useradd --create-home --shell /bin/sh node

RUN node -v && npm -v
```

This was tested with:

```bash
docker build -t edgekit-client:test ./client
```

The client image build succeeded with the updated Dockerfile.

## Adopted solution

The adopted solution is to install Node.js from the official Linux binary distribution inside the `leap-micro` image.

This preserves the `leap-micro` base image requirement while providing Node.js and npm without depending on unavailable Zypper packages.

## Implementation details

- The Docker base image remains `registry.opensuse.org/opensuse/leap-micro/6.1/toolbox:latest`.
- The Dockerfile installs the minimal tools required for download and archive extraction: `curl`, `tar`, `gzip`, and `xz`.
- The Node.js binary tarball is downloaded from `nodejs.org` and extracted into `/usr/local` with `--strip-components=1` so that `node` and `npm` are made available globally.
- A verification step runs `node -v && npm -v` during the build.
- Existing application install and copy steps remain unchanged.

## Impact

- The build no longer fails at the Node.js installation step for the client image.
- The `leap-micro` image is preserved as the base environment.
- The solution adds a small download and extraction step, but it avoids adding a large additional base image layer.
- The final image still contains a standard Node.js runtime compatible with the application requirements.
- The fix is suitable for local builds and can be incorporated into CI/CD as long as the Node.js binary URL remains available.
