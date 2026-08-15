---
title: What a unikernel is
description: One program, one address space, one purpose.
---

When developing an application, we usually rely on a standard interface
(commonly known as the [POSIX interface][posix]) provided by the operating
system to interact with hardware devices. In this classic architecture, only
the OS kernel has direct access to the physical hardware; it decides how to
schedule resources among programs so they can run simultaneously without
conflicting with one another.

The main advantage of this setup is portability: since POSIX is widely
supported, the same code can theoretically run on Linux, FreeBSD, or macOS.
However, each system still has its own quirks and subtle differences.
Furthermore, because POSIX is designed for general-purpose computing, it
includes a massive amount of software features that a specific application
might never actually need.

While this abstraction makes software development easier, it comes at the cost
of specialization. Developers are forced to include large blocks of unused code
by default which not only wastes resources, but also expands the overall
attack surface for security threats.

This is where unikernels emerge as a radical alternative: the application
effectively **becomes** the kernel. There is no longer any separation between
the user space and the OS. The application is the only process running within
this isolated environment, interacting with virtual devices provided by a
hypervisor. A unikernel is therefore a hyper-specialized operating system whose
sole purpose is to run your specific application, and nothing else.

[posix]: https://en.wikipedia.org/wiki/POSIX
