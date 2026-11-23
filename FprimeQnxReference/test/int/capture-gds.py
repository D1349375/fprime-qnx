#!/usr/bin/env python3
"""Record all decoded GDS events and telemetry using its standard pipeline."""

import signal
import threading

from fprime_gds.executables.cli import StandardPipelineParser


def main():
    args, _ = StandardPipelineParser.parse_args([StandardPipelineParser], description=__doc__)
    pipeline = StandardPipelineParser.pipeline_factory(args)
    stopped = threading.Event()

    def stop(signum, frame):
        stopped.set()

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    try:
        print("GDS capture ready", flush=True)
        stopped.wait()
    finally:
        pipeline.disconnect()


if __name__ == "__main__":
    main()
