---
title: Home
description: Building operating systems that do one thing with OCaml and Solo5.
---

A unikernel is a lightweight, specialized virtual machine where a single
application is compiled directly with only the minimal operating system
components it needs to run. It operates in a isolated environment with an attack
surface significantly smaller and more restricted than traditional containers.

Unlike traditional OSs that separate user applications from the kernel, a
unikernel bundles everything into a single, isolated image that runs directly
on a hypervisor (like KVM, BHyve, or OpenVMM). Because it removes unnecessary
drivers and background services, a unikernel is extremely small, fast to boot,
and efficient with resources.

Here, we will learn how to develop and deploy unikernels built using the
[OCaml][ocaml] language and the [Solo5][solo5] unikernel. These are the two
fundamental components that will then enable us to develop our own applications
in the form of unikernels, which we can subsequently deploy using
[Albatross][albatross].

[ocaml]: https://ocaml.org
[solo5]: https://github.com/solo5/solo5
[albatross]: https://github.com/robur-coop/albatross
