---
name: mfetch
version: 0.1.0
kind: tool
description: A tool to download sources of OCaml projects
repo: https://git.robur.coop/robur/mfetch
homepage: https://git.robur.coop/robur/mfetch
tags: [workflow, dependencies, vendoring]
authors:
  - name: Romain Calascibetta
    email: romain.calascibetta@gmail.com
    url: https://din.osau.re/
---

`mfetch` is a tool that allows you to download the source code for projects
specified in an `_mfetch` file. These projects can be specified in several
ways, but the most common method is to specify them using their `ocamlfind`
names.

The tool therefore aggregates all these projects and attempts to locate their
source code, which may be:
- the _tarball_ of the project's release
- a Git repository (local or remote)

`mfetch` then maintains a status of the downloaded source code in order to
detect any changes to it (so that possible _upstream_ patches can be
submitted).

Finally, `mfetch` can generate a `_mfetch.locked` file containing a description
(in OPAM format) of the source code the tool has downloaded (including their
hashes), thereby ensuring the reproducibility of a project using, for example,
[`orb`][orb].
