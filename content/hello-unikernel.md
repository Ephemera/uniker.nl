---
title: Your first unikernel
description: A program that boots, prints one line and stops.
---

To fully grasp how a unikernel works, we will build one from scratch using
[Solo5][solo5] in **C**. This hands-on approach will show you how to construct
such a hyper-specialized operating system and how to test it in a real
virtualized environment.

First, we need to install [OPAM][opam] and Solo5; we can do this as follows:
```shell
$ bash -c "sh <(curl -fsSL https://opam.ocaml.org/install.sh)"
$ opam init --compiler 5.5.0
$ opam install solo5
$ eval $(opam env)
```

## A simple "Hello World!"

Next, we’ll write a file called **main.c**.

::: annotate

Solo5 provides a minimal set of lower-level functions, which are the only ones
available at this level. Standard C functions like `memcpy` or POSIX functions
like `socket` do not exist yet. Instead, Solo5 provides bindings to interact
directly with virtual devices. Take a moment to explore these [API
functions][solo5-api], as they serve as the foundation for higher-level
languages like OCaml.

```c
#include "solo5.h"
```

```c
const char hello_world[] = "Hello World!\n";
```

The first entry point of a solo5 application is `solo5_app_main`. A single
argument is passed, which provides information such as the arguments or the
available memory.
```c
int solo5_app_main(const struct solo5_start_info *si) {
  solo5_console_write(hello_world, sizeof(hello_world));
  return (0);
}
```

:::

## A Solo5 manifest

A Solo5 unikernel also requires a _manifest_. This is a file that describes the
devices Solo5 needs in order to run. At this stage, we are not using one, but
we still need to link the manifest to our unikernel.

```json
{
  "type": "solo5.manifest",
  "version": 1,
  "devices": []
}
```

## Compilation

Using these source files, we can now compile our unikernel. The Solo5 project
provides what is known as a _toolchain_ – a set of tools that enables us to
compile the source code correctly and link it to produce the unikernel. Here’s
how to use them:

::: annotate

```shell
$ x86_64-solo5-none-static-cc -c main.c -o main.o
$ x86_64-solo5-none-static-cc -c manifest.c -o manifest.o
$ solo5-elftool gen-manifest manifest.json manifest.c
```

The `-z solo5-abi=hvt` option is specific to Solo5 (and should be ignored by
the underlying C compiler). It allows you to specify which ABI you wish to use.
Solo5 offers an ABI for `solo5-hvt`, as well as for VirtIO, Muen and Xen. We
will discuss this parameter in more detail later.

```shell
$ x86_64-solo5-none-static-ld -z solo5-abi=hvt manifest.o main.o -o main.hvt
```

:::

## Execution

You can now run the programme. To do so, you simply need to have access to the
group that authorises the use of your system’s hypervisor (for example, on
Linux, you must be a member of the `kvm` group), and you can now launch your
unikernel as follows:

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

Well done! You've built your first unikernel.

[solo5]: https://github.com/solo5/solo5
[solo5-api]: https://github.com/Solo5/solo5/blob/main/include/solo5.h
[opam]: https://opam.ocaml.org/
