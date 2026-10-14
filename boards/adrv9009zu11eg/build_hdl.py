#!/usr/bin/env python3
"""Build the ADRV9009-ZU11EG + ADRV2CRR-FMC bitstream with the GPS pps_counter.

  python boards/adrv9009zu11eg/build_hdl.py --hdl Z:/hdl --vivado F:/Xilinx/Vivado/2023.2/bin/vivado.bat
  python boards/adrv9009zu11eg/build_hdl.py ... --skip-synthesis   # no license needed

Steps: clone ADI HDL at the pinned tag if --hdl is missing, apply
apply_hdl_patch.py, package the ADI IP libraries the project needs, then run
the project. Replaces ADI's make flow so it also runs on Windows without
make/Cygwin; Vivado is always launched natively.

--skip-synthesis (ADI_SKIP_SYNTHESIS) builds and validates the block design
and generates its targets but stops before synthesis. That part needs no
license, so it checks every patch on any PC. Synthesis and implementation
for xczu11eg need a Vivado Enterprise (or evaluation) license.

On Windows keep --hdl short (e.g. a subst drive): Vivado's generated IP
paths under projects/adrv9009zu11eg/adrv2crr_fmc exceed MAX_PATH otherwise.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

ADI_HDL_URL = "https://github.com/analogdevicesinc/hdl.git"
ADI_HDL_TAG = "2023_R2_p1"            # hdl_2023_r2, Vivado 2023.2
PROJECT = "projects/adrv9009zu11eg/adrv2crr_fmc"
BOARD = Path(__file__).resolve().parent


def norm(p: Path) -> Path:
    """Absolute and normalised, but NOT resolve(): that would undo a subst drive."""
    return Path(os.path.normpath(os.path.abspath(p)))


def mk_vars(makefile: Path) -> dict:
    """The NAME := / += assignments of an ADI Makefile (enough for its deps)."""
    out: dict = {}
    for raw in makefile.read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        m = re.match(r"^([A-Z_]+)\s*(\+=|:=|=)\s*(.*)$", line)
        if not m:
            continue
        name, op, val = m.groups()
        vals = val.split()
        if op == "+=":
            out.setdefault(name, []).extend(vals)
        else:
            out[name] = vals
    return out


class Builder:
    def __init__(self, hdl: Path, vivado: str, log_dir: Path):
        self.hdl, self.vivado, self.log_dir = hdl, vivado, log_dir
        self.lib = hdl / "library"
        self.done: set = set()

    def vivado_batch(self, cwd: Path, tcl: str, log_name: str, env=None) -> None:
        log = self.log_dir / log_name
        cmd = [self.vivado, "-mode", "batch", "-nojournal", "-log", str(log), "-source", tcl]
        t0 = time.time()
        print(f"[RUN ] {cwd.relative_to(self.hdl)}: vivado -source {tcl}", flush=True)
        r = subprocess.run(cmd, cwd=cwd, env=env, stdout=subprocess.DEVNULL,
                           stderr=subprocess.STDOUT)
        print(f"[{'OK' if r.returncode == 0 else 'FAIL':4}] {tcl} ({time.time() - t0:.0f} s, log {log})",
              flush=True)
        if r.returncode != 0:
            raise SystemExit(f"Vivado failed in {cwd}; see {log}")

    def interfaces(self, d: Path) -> None:
        d = norm(d)
        if d in self.done:
            return
        tcl = d / "interfaces_ip.tcl"
        if not tcl.exists():
            raise SystemExit(f"interface dir without interfaces_ip.tcl: {d}")
        stamp = d / ".gps-timing-built"                  # ADI commits some of the .xml
        if not stamp.exists():
            self.vivado_batch(d, tcl.name, f"intf_{d.parent.name}_{d.name}.log")
            stamp.touch()
        self.done.add(d)

    def library(self, d: Path) -> None:
        d = norm(d)
        if d in self.done:
            return
        v = mk_vars(d / "Makefile")
        for dep in v.get("XILINX_INTERFACE_DEPS", []):
            self.interfaces(self.lib / dep)
        for dep in v.get("XILINX_DEPS", []):
            if dep.endswith(".xml") and not (d / dep).exists():
                self.interfaces((d / dep).parent)
        for dep in v.get("XILINX_LIB_DEPS", []):
            self.library(self.lib / dep)
        if not (d / "component.xml").exists():
            name = v["LIBRARY_NAME"][0]
            self.vivado_batch(d, f"{name}_ip.tcl", f"lib_{name}.log")
        self.done.add(d)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--hdl", required=True, type=Path, help="ADI HDL tree (cloned if missing)")
    ap.add_argument("--vivado", required=True, help="vivado executable (vivado.bat on Windows)")
    ap.add_argument("--skip-synthesis", action="store_true",
                    help="stop after the block design (no license needed)")
    ap.add_argument("--ooc-jobs", type=int, default=4, help="ADI_MAX_OOC_JOBS")
    args = ap.parse_args()

    hdl = args.hdl
    if not (hdl / PROJECT).exists():
        print(f"[INFO] cloning ADI HDL {ADI_HDL_TAG} into {hdl}", flush=True)
        subprocess.run(["git", "-c", "core.longpaths=true", "clone", "--depth", "1",
                        "--branch", ADI_HDL_TAG, ADI_HDL_URL, str(hdl)], check=True)
    hdl = norm(hdl)
    subprocess.run([sys.executable, str(BOARD / "apply_hdl_patch.py"), str(hdl)], check=True)

    log_dir = hdl / "gps-timing-logs"
    log_dir.mkdir(exist_ok=True)
    b = Builder(hdl, args.vivado, log_dir)
    proj = hdl / PROJECT
    for dep in mk_vars(proj / "Makefile").get("LIB_DEPS", []):
        b.library(b.lib / dep)

    for stale in proj.glob("adrv9009zu11eg.*"):
        shutil.rmtree(stale, ignore_errors=True)
    env = dict(os.environ, ADI_MAX_OOC_JOBS=str(args.ooc_jobs))
    if args.skip_synthesis:
        env["ADI_SKIP_SYNTHESIS"] = "1"
    b.vivado_batch(proj, "system_project.tcl", "project.log", env=env)

    if args.skip_synthesis:
        print("[DONE] block design built and validated (synthesis skipped)")
        return
    bit = proj / "adrv9009zu11eg.runs/impl_1/system_top.bit"
    xsa = proj / "adrv9009zu11eg.sdk/system_top.xsa"
    timing = proj / "adrv9009zu11eg.runs/impl_1/system_top_timing_summary_routed.rpt"
    for f in (bit, xsa, timing):
        if not f.exists():
            raise SystemExit(f"expected build output missing: {f}")
    met = "All user specified timing constraints are met." in timing.read_text(errors="replace")
    out = hdl / "gps-timing-out"
    out.mkdir(exist_ok=True)
    shutil.copy2(bit, out / "system_top.bit")
    shutil.copy2(xsa, out / "system_top.xsa")
    print(f"[DONE] {out / 'system_top.bit'}  timing {'MET' if met else 'NOT MET -- see ' + str(timing)}")
    if not met:
        sys.exit(2)


if __name__ == "__main__":
    main()
