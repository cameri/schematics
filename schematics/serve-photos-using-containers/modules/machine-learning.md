# Module: machine-learning

The inference service behind smart search and face recognition: what it costs,
which knobs bound that cost, how a GPU is attached, and what its cache is worth.

## Purpose

This module owns the machine-learning container: the model it loads, the threads
it is allowed, the device it may use, and the volume its models download into. It
is NOT responsible for the job queue's scheduling — the server owns that — and it
does not touch the database or the originals beyond telling the server what it
found.

## Inputs

- The machine-learning image reference: the tag suffixed by `ML_BACKEND` and
  pinned by `ML_DIGEST`.
- `MACHINE_LEARNING_REQUEST_THREADS`, `MACHINE_LEARNING_WORKERS`,
  `MACHINE_LEARNING_MODEL_TTL`, `ML_CPU_LIMIT` from the Parameters table.
  `ML_CPU_LIMIT` reaches the container as its Compose CPU limit; `0` means no
  ceiling, and the acceptance runner fails when a recorded value is not in force.
- The model-cache volume from `media-storage`.
- Requests from the server: embeddings for smart search, face and object
  detections during indexing.

## Outputs

- Embeddings and detections returned over HTTP on the Compose network, which the
  server writes into the database.
- Models downloaded into the cache volume on first use, and unloaded after
  `MACHINE_LEARNING_MODEL_TTL` seconds of inactivity.
- Log lines naming the inference provider, which are the evidence A-9 checks.

## Dependencies

- D-1 (Docker Engine + Compose), D-3 (machine-learning image), D-6 (storage), D-7
  (a GPU, optional).
- P-9, P-11, P-17, P-18, P-19, P-20.

## Failure Behavior

- **The container is absent or stopped.** The library browses, uploads, and
  albums work; smart search returns nothing and recognition jobs sit in the
  queue. This is a deliberate degrade, not an error state, so the acceptance test
  treats "machine learning down" and "smart search broken" as different things.
- **Container restarts under load.** Two causes, in order of likelihood: memory
  (each worker duplicates its models in memory, so `MACHINE_LEARNING_WORKERS` multiplies the
  footprint) and the worker timeout. Fix with fewer workers or threads, or a
  shorter `MACHINE_LEARNING_MODEL_TTL` so idle models return memory sooner.
- **CPU saturated during the first index.** Expected, not a failure: this is the
  peak-load event R-7 exists for. Bound it with `MACHINE_LEARNING_REQUEST_THREADS` and
  `ML_CPU_LIMIT`, and schedule the pass rather than discovering it.
- **A GPU is selected but unused.** The image tag and the device passthrough must
  agree with the backend: the tag carries the suffix and the passthrough comes
  from the acceleration file. A tag without a device, or a device without the
  tag, produces a CPU run with no error. Detect from the log line naming the
  inference provider, not from the absence of errors.
- **The cache volume is missing.** Models download again on the next inference;
  the pass is slower and needs network access to the model registry. Data is not
  lost.

## Sizing, stated plainly

The two parameters that matter when the host is small are the thread pool and
the worker count, and the upstream documentation names the thread pool as the
one to tune first; the worker count duplicates models in memory and is not
recommended as a first lever.

The measured cost on the reference host, during a first-time index of an
existing library: roughly 40% of total host CPU sustained in the machine-learning
container, with package temperature rising from 55 °C to 58 °C against a trip
point of 120 °C. *(observed)* Read that as a shape rather than a number: the
service uses whatever share of the CPU it is given for as long as the pass lasts,
so a host with no thermal headroom — a fanless NAS, a small-form-factor machine,
a shared hypervisor — needs `MACHINE_LEARNING_REQUEST_THREADS` set below the core count before
the first pass starts, not after the host has already throttled.

## Hardware acceleration

The backend is a parameter, not an edit. Two coordinated values select it: the
image tag's suffix and the device passthrough. Backends the upstream project
supports, with what each needs from the host:

| Backend | Tag suffix | Host requirement |
|---------|-----------|------------------|
| CPU (default) | none | nothing beyond the host's cores |
| ARM NN | `-armnn` | a Mali GPU (`/dev/mali0`) and the closed-source userspace driver, whose paths the acceleration file assumes |
| CUDA | `-cuda` | an NVIDIA GPU with compute capability 5.2+, driver ≥ 545, and the NVIDIA container toolkit on Linux |
| ROCm | `-rocm` | an AMD GPU supported by ROCm and the kernel driver; the image needs roughly 35 GB free during the pull |
| OpenVINO | `-openvino` | an Intel GPU; integrated GPUs are the least reliable option and use more RAM than CPU inference |
| RKNN | `-rknn` | a supported Rockchip SoC and driver ≥ 0.9.8 |
| OpenVINO under WSL2 | `-openvino-wsl` | the same as OpenVINO with the WSL device paths and a driver name the acceleration file sets |

Enabling acceleration later requires no re-run of machine-learning jobs: the
device is used by whatever runs after it is attached. *(observed)* Confirm the
device is genuinely in use by the provider named in the container's log — for
OpenVINO and CUDA, a list of available inference providers; for ARM NN, a model
load line without errors — or by watching GPU utilisation with a tool such as
`nvtop` for NVIDIA and Intel or `radeontop` for AMD.

Transcoding is a separate acceleration decision with its own backends (`nvenc`,
`quicksync`, `rkmpp`, `vaapi`, and `vaapi-wsl`) and its own device passthrough;
it concerns video playback rather than inference, and either can be enabled
without the other.

## Idempotency Notes

- Restarting the container is always safe; models are re-downloaded into the
  cache only if the volume is gone.
- Changing a machine-learning parameter requires the container to be recreated,
  not restarted: `docker compose up -d immich-machine-learning`.
- Removing the cache volume between runs is a supported way to force a clean
  download and costs a re-download only.

## Removal Notes

The container, its cache volume, and the parameters above are the whole
footprint; embeddings already stored in the database remain, and smart search
keeps working against them until the server is asked to re-index. Removing the
module turns the instance into a plain photo library: uploads, albums, and
browsing continue.
