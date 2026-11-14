# VC Static Lint — belenos

Signoff-grade structural lint for the Belenos graphic controller. Separate from
and additional to the Verilator lint in `sim/rtl_sim/run/run_lint`; neither
replaces the other.

## Usage

Run from this directory, with `vc_static_shell` on PATH:

```bash
./run_vclint                      # classic (config 3, the RTL defaults): structural + netlist + quick-lint
./run_vclint -rtl_config light    # config 1, no GPU
./run_vclint -rtl_config <N|name> # lint one config from sim/rtl_sim/bin/rtl_configs.py
./run_vclint -rtl_sweep           # lint every config; summary only
./run_vclint -list_configs        # print the config table
./run_vclint -lang                # add the LANGUAGE_CHECK stage (slower, noisier)
./run_vclint -lang -j <count>     # ... with <count> parallel language-check processes (default 8)
./run_vclint -top <module>        # lint a submodule instead of the config's top
./run_vclint -raw                 # ignore rules.tcl -- report every enabled rule
./run_vclint -i                   # leave vc_static_shell open for interactive triage
./run_vclint -h                   # full option list
```

A bare `./run_vclint` lints `classic` (configuration 3 of the table), the RTL defaults,
GPU included; configuration 1, `light`, has no GPU. A bare run is not snapshotted to
`results_sweep/`; give `-rtl_config classic` for that.

Reports land in `results/`; a `-rtl_config` run also snapshots them to
`results_sweep/<label>/`. `-rtl_sweep` writes only
`results_sweep/sweep_summary.log`, one line per config — to investigate a row,
re-run that config on its own with `-rtl_config`.

The config table is `sim/rtl_sim/bin/rtl_configs.py`, the single source of
truth shared with the Verilator lint sweep (`./run_lint -sweep`) and synthesis
(`run_syn -rtl_config`). The translation to Tcl is
`sim/rtl_sim/bin/gen_rtl_params.py`, which also emits the `RTL_PARAM_*` values
that `rules.tcl` and `waivers.tcl` branch on — reset style above all, since the
two reset rules are mutually exclusive and the `sync_rst*` configs need the
opposite one from the defaults. `./run_vclint -list_configs` prints the table.

`stale=0` is the signal to protect: it means every waiver in `waivers.tcl`
matched something. A non-zero count means a waiver has gone stale or is scoped
to a configuration that is not being linted. It is an invariant of the
rule-policy, default-stage run of a config at its own top; it does not hold,
and is not meant to, under `-raw` or under `-top <submodule>`.

## Policy files

- `rules.tcl` — per-tag enable/disable, derived from
  `arvern/lint/vc_static/rules.tcl`; it is house policy, not design-specific.
  The rule policy is the same as the arvern copy's (only the header differs),
  `CODING_PARAMETER_NOT_USED`, the dead-parameter check, included (it reports
  under `-lang` only).
- `waivers.tcl` — design waivers for this IP, commented in place.
