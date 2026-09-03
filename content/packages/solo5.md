---
name: Solo5
version: 0.12.0
kind: library
description: A sandboxed execution environment for unikernels
repo: https://github.com/solo5/solo5
homepage: https://github.com/solo5/solo5
tags: [hypervisor, sandbox, bindings, C]
authors:
  - name: Martin Lucina
    email: martin@lucina.net
maintainers:
  - name: Romain Calascibetta
    email: romain.calascibetta@gmail.com
    url: https://din.osau.re/
  - name: Hannes Mehnert
    email: hannes@mehnert.org
    url: https://hannes.robur.coop/
---

Solo5 is a framework for building unikernels in C. It provides a _toolchain_
for compiling C projects and producing unikernels, as well as _tenders_ for
running those unikernels.

Solo5 enables the creation of unikernels that can be run using `solo5-hvt` (the
Solo5 tender), `solo5-spt` (the Solo5 tender that uses
[`libseccomp`][libseccomp]), [`qemu`][qemu], [Xen][xen] or [Muen][muen]. It
therefore supports several backends, which the user can select using the `-z`
option. The different backends are as follows:
- `hvt` is the Solo5 backend. It produces a unikernel that can be run using
  `solo5-hvt`, which is the _tender_ distributed with Solo5.
- `xen` produces a unikernel that can be run by the Xen hypervisor.
- `virtio` generates a unikernel that can be run by `qemu`. It also enables the
  creation of unikernels that can be deployed on platforms such as Google
  Compute Engine ([GCE][gce])
- `spt` produces a Linux executable that can be run using `solo5-spt`. The
  latter uses `libseccomp` to _sandbox_ the unikernel's execution.
- `muen` enables the creation of compatible unikernels that can run on Muen (a
  Separation Kernel for x86/64).

## How to install it?

Solo5 is a C project, but it is part of the OCaml ecosystem. It is therefore
available via [OPAM][opam] if you wish. It can also be installed via `apt` or
`pkg`.  Our cooperative offers a Debian and FreeBSD repository where Solo5 is
available. Here are the different ways to install Solo5:

### Via [OPAM][opam]

```shell
$ bash -c "sh <(curl -fsSL https://opam.ocaml.org/install.sh)"
$ opam init --compiler 5.5.0
$ opam install solo5
$ eval $(opam env)
$ solo5-hvt --version
solo5-hvt tender, version v0.12.0
ABI version 2
```

### Via `apt` (for Debian)

```shell
$ curl -fsSL https://apt.robur.coop/gpg.pub \
  | gpg --dearmor > /etc/apt/trusted.gpg.d/apt.robur.coop.gpg
$ cat > /etc/apt/sources.list.d/robur.sources <<END
Types: deb
URIs: https://apt.robur.coop
Suites: debian-13
Components: main
Signed-By: /etc/apt/trusted.gpg.d/apt.robur.coop.gpg
END
$ apt update
$ apt install solo5
$ solo5-hvt --version
solo5-hvt tender, version v0.12.0
ABI version 2
```

### Via `pkg` (for FreeBSD)

```shell
$ fetch -o /usr/local/etc/pkg/robur.pub https://pkg.robur.coop/repo.pub
$ echo 'robur: {
  url: "https://pkg.robur.coop/${ABI}",
  mirror_type: "srv",
  signature_type: "pubkey",
  pubkey: "/usr/local/etc/pkg/robur.pub",
  enabled: yes
}' > /usr/local/etc/pkg/repos/robur.conf
$ pkg update
$ pkg install solo5 albatross
```

## How to use it?

Solo5 provides a toolchain for building a C unikernel, as well as a tool for
running this unikernel called `solo5-hvt`. Here is a brief example of how to
create a C unikernel. You must first implement the **solo5_app_main** function,
which is known as the first entry point of a Solo5 application.

```c
#include "solo5.h"

const char hello_world[] = "Hello World!\n";

int solo5_app_main(const struct solo5_start_info *si) {
  solo5_console_write(hello_world, sizeof(hello_world));
  return (0);
}
```

A unikernel always requires a manifest listing the devices it wishes to use:
Solo5 does not _discover_ devices, but expects the devices described in its
manifest to be available. In this case, we are going to create a JSON file for
which we do not have any devices.

```json
{
  "type": "solo5.manifest",
  "version": 1,
  "devices": []
}
```

We can now compile our unikernel using these two files and Solo5:

:::annotate

```shell
$ x86_64-solo5-none-static-cc -c main.c -o main.o
$ solo5-elftool gen-manifest manifest.json manifest.c
$ x86_64-solo5-none-static-cc -c manifest.c -o manifest.o
```

Solo5 offers several ABIs: `hvt` (if you want to run the unikernel with
`solo5-hvt`), `xen` (if you want to run the unikernel with the [Xen
hypervisor][xen]), `virtio` (if you can run the unikernel with [`qemu`][qemu]).
There is also support for [Muen][muen].

```shell
$ x86_64-solo5-none-static-ld -z solo5-abi=hvt manifest.o main.o -o main.hvt
```

:::

Since we have compiled our unikernel with the `hvt` ABI, we can now run our
unikernel using `solo5-hvt`. Please note that you must have the necessary
permissions to run a unikernel. On Linux, you simply need to be a member of the
`kvm` group.

```shell
$ sudo usermod -aG kvm $USER
$ solo5-hvt main.hvt
            |      ___|
  __|  _ \  |  _ \ __ \
\__ \ (   | | (   |  ) |
____/\___/ _|\___/____/
Solo5: Bindings version v0.12.0
Solo5: Memory map: 512 MB addressable:
Solo5:   reserved @ (0x0 - 0xfffff)
Solo5:       text @ (0x100000 - 0x104fff)
Solo5:     rodata @ (0x105000 - 0x105fff)
Solo5:       data @ (0x106000 - 0x30afff)
Solo5:       heap >= 0x30b000 < stack < 0x20000000
Hello World!
Solo5: solo5_exit(0) called
```

## API

Solo5 offers several functions available within your unikernel. These are all
accessible through the `solo5.h` file, which users can include. Here is the
documentation covering everything you can do with your unikernel.

::: document

```c
void solo5_console_write(const char *buf, size_t size);
```

You can write to the tender's standard output using the `solo5_console_write`
function. This function operates on a best-effort basis and may potentially
lose some data.

---

```c
typedef enum {
```

### Error

For functions returning a `solo5_result_t`:
- they return only `SOLO5_R_OK` on success.
- Application developpers must not rely on these functions returning
  `SOLO5_R_EINVAL` or `SOLO5_R_EUNSPEC`. Solo5 implementations may choose to
  abort execution of the application in preference to returning an error result
  on failure.

```c
    SOLO5_R_OK = 0,
```

The operation completed successfully.

```c
    SOLO5_R_AGAIN,
```

The operation cannot be completed at this time. Retrying identical operation at
a later time may succeed.

```c
    SOLO5_R_EINVAL,
```

Invalid argument.

```c
    SOLO5_R_EUNSPEC
```

The operation failed due to an unspecified error.

```c
} solo5_result_t;
```

---

```c
struct solo5_start_info {
```

```c
    const char *cmdline;
```

The parameters passed to the _tender_ are transferred to the unikernel in the
form of a read-only string ending with `\0`.

```c
    uintptr_t heap_start;
    size_t heap_size;
```

A unikernel has at its disposal a continuous, non-executable memory region
defined by `[heap_start, heap_start+heap_size]`. This region can, in
particular, be used by an implementation of `malloc(3)`. Also, a C stack is
already initialised at the top of this region and grows downwards.

```c
};

```

---

```c
int solo5_app_main(const struct solo5_start_info *info);
```

Application entry point. A Solo5 application must implement the
`solo5_app_main` function, and this is the function that will be executed first
when the unikernel starts up. A statically allocated `solo5_start_info` value
(read-only) is passed to it.

Here is an example of a small Solo5 application:
'''c
#include "solo5.h"

const char hello_world[] = "Hello World!\n";

int solo5_app_main(const struct solo5_start_info *info) {
  solo5_console_write(hello_world, sizeof(hello_world));
  return (0);
}
'''

---

```c

#define SOLO5_EXIT_SUCCESS 0
#define SOLO5_EXIT_FAILURE 1
#define SOLO5_EXIT_ABORT   255

```

```c
void solo5_exit(int status) __attribute__((noreturn));
```

`solo5_exit` is used to terminate a unikernel. It (attempts to) return the
value passed as a parameter to the host.

```c
void solo5_abort(void) __attribute__((noreturn));
```

`solo5_abort` is used to shut down the unikernel. The host then returns the
value 255.

---

### Thread Local Storage

This implementation of TLS is limited to the [local-exec model][tls-model]
(offset directly from the `TLS_BASE` register) which is how Solo5 currently use TLS.
The usage is as the following for each thread:

'''c
// define a TLS block
uintptr_t tcb1;
// get memory
tcb1 = (uintptr_t) calloc(solo5_tls_size(), sizeof(char));
// initialize TLS block
solo5_tls_init(tcb1);
// set tp ptr
solo5_set_tls_base(solo5_tls_tp_offset(tcb1));
'''

For another thread, you just have to:

'''c
solo5_set_tls_base(solo5_tls_tp_offset(tcb2));
'''

---

```c
size_t solo5_tls_size(void);
```

Returns the size needed for the thread local storage.

---

```c
uintptr_t solo5_tls_tp_offset(uintptr_t tls);
```

Returns the `tp` base addresse for the TLS block.

---

```c
solo5_result_t solo5_tls_init(uintptr_t tls);
```

Perform a proper initialisation of the `tls` block (it should be already
allocated): copy `.tdata` values and set the last bytes correctly.

Solo5 implementations may return `SOLO5_R_EINVAL` if the `tls` does not satisfy
architecture specific requirements.

---

```c
solo5_result_t solo5_set_tls_base(uintptr_t base);
```

Set the architecture specific TLS base register to `base`.

Solo5 implementations may return `SOLO5_R_EINVAL` if the `base` does not
satisfy architecture specific requirements.

---

```c
typedef uint64_t solo5_time_t;
```

### Time

Solo5 implements two clocks:
- a so-called _monotonic_ clock, which tracks how much time has elapsed. This
  clock is not subject to any recalibration or changes. It increments
  monotonically.
- a so-called _wall_ clock, which corresponds to the host system's POSIX clock.
  It may be subject to recalibration and jumps.

The elapsed time `solo5_time_t` is given in nanoseconds.

---

```c
solo5_time_t solo5_clock_monotonic(void);
```

As the monotonic clock does not do recalibration, a _drift_ in the clock
relative to real time may be observed. This clock is what is known as a
TimeStamp-Counter-based clock: in other words, it increases monotonically in
relation to the calculated frequency of the vCPU and the number of instructions
it has executed.

In other words, this clock is useful if you can calculate or estimate a short
period of time (less than a day), but it becomes out of sync over longer
periods.

---

```c
solo5_time_t solo5_clock_wall(void);
```

The wall clock is therefore more accurate than the monotonic clock. However,
depending on the backend, a hypercall may be executed, which makes this clock
run slower.

---

### Input/Output

Solo5 provides a way of interacting with virtual ‘devices’ that are directly
available and connected via the tender being used. These devices are
- `net` devices (which correspond to TAP interfaces: or, more practically,
  Ethernet sockets)
- `block` devices (which correspond to areas where pages can be read from and
  written to: which, in practical terms, may correspond to SATA sockets).

---

```c
typedef uint64_t solo5_handle_t;
```

These devices are represented on the unikernel side by a `solo5_handle_t`. It
is through these values that the unikernel can interact with these devices. You
can obtain such a value using the `solo5_*_acquire` functions.

---

```c
typedef uint64_t solo5_handle_set_t;
```

Type for sets of up to 64 I/O handles.

---

```c
void solo5_yield(solo5_time_t deadline, solo5_handle_set_t *ready_set);
```

Suspends executon of the application until either:
- monotonic time reaches `deadline`, or
- at least one network device is ready for input

If `ready_set` is not NULL, it will be filled in with the set of
`solo5_handle_t`'s ready for input.

This function is generally referred to as the _poll point_ for retrieving
events relating to devices (namely, the arrival of an Ethernet frame on one of
our network devices).

---

```c
#define SOLO5_NET_ALEN 6
#define SOLO5_NET_HLEN 14

struct solo5_net_info {
    uint8_t mac_address[SOLO5_NET_ALEN];
    size_t mtu; /* Not including Ethernet header */
};
```

#### Network

A Solo5 unikernel can manage a network device (which, in practice, may
correspond to an Ethernet port). This device can be configured via the tender,
and you can, in particular, set a specific MAC address and a specific Maximum
Transmission Unit (MTU). Ethernet frames are expected to be written (using
`solo5_net_write`) and received (using `solo5_net_read`).

Here is an example of how to invoke `solo5-hvt` to attach a TAP interface as a
network device to the unikernel (with a specific MAC address and a specific
MTU):

'''shell
$ ip tuntap add tap0 mode tap
$ ip link set dev tap0 up mtu 1500
$ solo5-hvt --net:service=tap0 --net-mac:service=11:7e:cf:4b:e7:db \
  -- unikernel.hvt
'''

---

```c
solo5_result_t solo5_net_acquire(const char *name, solo5_handle_t *handle,
                                 struct solo5_net_info *info);
```

`solo5_net_acquire` acquires a handle to the network device declared as `name`
in the application manifest. The returned handle is stored in `*handle`, and
properties of the network device are stored in `*info`. Caller must supply
space for `struct solo5_net_info` in `info`. This function may only be called
once for each device `name`. Subsequent calls will return `SOLO5_R_EINVAL`.

---

```c
solo5_result_t solo5_net_write(solo5_handle_t handle, const uint8_t *buf,
                               size_t size);
```

Sends a single network packet to the network device identified by `handle`,
from the buffer `*buf`, without blocking. If the packet cannot be sent due to a
transient error (e.g. no resources available) it will be silently dropped.

The maximum allowed value for `size` is `solo5_net_info.mtu + SOLO5_NET_HLEN`.
The packet must include the ethernet frame header.

---

```c
solo5_result_t solo5_net_read(solo5_handle_t handle, uint8_t *buf, size_t size,
                              size_t *read_size);
```

Receives a single network packet from the network device identified by `handle`
into the buffer `*buf`, without blocking. `size` must be aat least
`solo5_net_info.mtu + SOLO5_NET_HLEN`).

If not packets are available, it returns `SOLO5_R_AGAIN`. Otherwise, it returns
`SOLO5_R_OK` and the size of the received packet including the ethernet frame
header in `*read_size`.

---

#### Block device

```c
typedef uint64_t solo5_off_t;

struct solo5_block_info {
    solo5_off_t capacity; /* Capacity of block device, bytes */
    solo5_off_t block_size; /* Minimum I/O unit (block size), bytes */
};
```

Information relating to a block device when Solo5 is accessing one. The minimum
unit of I/O which can be performed on a block device is defined by
`solo5_block_info.block_size` (known as _sector size_). In other words, reading
and writing take place in sectors (rather than bytes).

---

```c
solo5_result_t solo5_block_acquire(const char *name, solo5_handle_t *handle,
                                   struct solo5_block_info *info);
```

Acquire a handle to the block device declared as `name` in the application
manifest.  The returned handle is stored in `*handle`, and properties of the
block device are stored in `*info`. Caller must supply space for `struct
solo5_block_info` in `info`.  This function may only be called once for each
device `name`. Subsequent calls will return `SOLO5_EINVAL`.

---

```c
solo5_result_t solo5_block_write(solo5_handle_t handle, solo5_off_t offset,
                                 const uint8_t *buf, size_t size);
```

Writes data of `size` bytes from the buffer `*buf` to the block device
identified by `handle`, starting at byte `offset`. Data is either written in
it's entirety or not at all ("short writes" are not possible).

Both `size` and `offset` must be a multiple of the block size/_sector size_,
otherwise `SOLO5_R_EINVAL` is returned.

---

```c
solo5_result_t solo5_block_read(solo5_handle_t handle, solo5_off_t offset,
                                uint8_t *buf, size_t size);
```

Reads data of `size` bytes into buffer `*buf` from the block device identified
by `handle`, starting at byte `offset`.  Always reads the full amount of `size`
bytes ("short reads" are not possible).

Both `size` and `offset` must be a multiple of the block size/_sector size_,
otherwise `SOLO5_R_EINVAL` is returned.

:::

[xen]: https://xenproject.org/
[muen]: https://muen.sk/
[libseccomp]: https://github.com/seccomp/libseccomp
[qemu]: https://www.qemu.org/
[gce]: https://cloud.google.com/products/compute
[opam]: https://opam.ocaml.org/
[tls-model]: https://www.akkadia.org/drepper/tls.pdf
