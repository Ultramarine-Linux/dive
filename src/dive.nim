import std/[strutils, strformat, paths, os, dirs, files, osproc]
import asyncdispatch
import cligen, sweet
import log, mounts

let mounteds = getMounts()

proc is_mountpoint(root: Path): bool =
  for mount in mounteds:
    if root == mount.mountpoint.Path:
      return true

proc mkdir(dir: Path) =
  try: dir.createDir
  except OSError:
    error "Cannot create dir: " & dir.string
    quit 1

proc run(cmd: string) {.async.} =
  info "Running command: "&cmd
  let p = startProcess("sh", args=["-c", cmd], options={poParentStreams})
  while p.running:
    await sleepAsync 10
  let rc = p.waitForExit
  if !!rc:
    fatal "Fail to execute command: "&cmd
    fatal "Command returned exit code: " & $rc
    quit 1

proc force_mountpoint(root: Path) {.async.} =
  if root.is_mountpoint: return
  warn fmt"{root.string} is not a mountpoint, bind-mounting…"
  await run fmt"mount --bind {root.string.quoteShell} {root.string.quoteShell}"

proc mount(path: Path, mountargs: string) {.async.} =
  if !path.is_mountpoint:
    mkdir path
    await run "mount "&mountargs&" "&path.string

proc mount_dirs(root: Path) {.async.} =
  await mount(root/"proc".Path, "-t proc proc") and
    mount(root/"sys".Path, "-t sysfs sys") and
    mount(root/"dev".Path, "-o bind /dev") and
    mount(root/"dev/pts".Path, "-o bind /dev/pts")

proc cp_resolv(root: Path) {.async.} =
  if !"/etc/resolv.conf".Path.fileExists:
    warn "/etc/resolv.conf does not exist"
    return
  let dest = root/"etc/resolv.conf".Path
  if !dest.fileExists:
    warn "Refusing to copy resolv.conf because it doesn't exist inside chroot"
    return
  await run "mount -c --bind /etc/resolv.conf "&dest.string

proc umount(path: string) {.async.} =
  try: await run fmt"umount {path}"
  finally: discard

proc umount_all(root: string) {.async.} =
  await umount(fmt"{root}/proc") and
    umount(fmt"{root}/sys") and
    umount(fmt"{root}/dev {root}/dev/pts") and
    umount(fmt"{root}/etc/resolv.conf")

proc find_shell(root: Path): string =
  if fileExists root/"bin/fish".Path:
    return "/bin/fish"
  if fileExists root/"bin/zsh".Path:
    return "/bin/zsh"
  if fileExists root/"bin/bash".Path:
    return "/bin/bash"
  if fileExists root/"bin/sh".Path:
    return "/bin/sh"
  warn "Cannot detect any shell in the chroot… falling back to /bin/sh"
  "/bin/sh"

proc dive(args: seq[string], verbosity = lvlNotice, keepresolv = false) =
  ## A chroot utility
  if !args.len:
    fatal "You must provide an argument for the root directory"
    quit 1
  let root = args[0].Path
  let cp_resolv_fut = cp_resolv root
  waitFor (force_mountpoint root) and (mount_dirs root) and cp_resolv_fut
  waitFor cp_resolv_fut
  let shell = find_shell root
  let str_args = args[1..^1].join(" ")
  waitFor run fmt"SHELL={shell} chroot {root.string} {str_args}"
  waitFor umount_all(root.string)


dispatch dive, help = {
  "args": "<root directory> [shell command]",
  "verbosity": "set the logging verbosity: {lvlAll, lvlDebug, lvlInfo, lvlNotice, lvlWarn, lvlError, lvlFatal, lvlNone}",
}, short = {"keepresolv": 'r'}
