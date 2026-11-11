#!/usr/bin/env python3
"""Measure a specified core dylib against a disposable vault, without user data.

Run each before/after dylib in a separate process. The UI benchmark lives in
UIPerformanceTests; these numbers measure only local core policy checks.
"""
import argparse
import ctypes
import json
import math
from pathlib import Path
import sqlite3
import statistics
import tempfile
import threading
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--library', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    core = ctypes.CDLL(str(args.library.resolve()))
    core.tp_core_call.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
    core.tp_core_call.restype = ctypes.c_void_p
    core.tp_core_free.argtypes = [ctypes.c_void_p]

    def call(fields):
        data = json.dumps(dict(apiVersion=1, **fields)).encode()
        pointer = core.tp_core_call(data, len(data))
        if not pointer:
            raise RuntimeError('Core returned no response')
        try:
            response = json.loads(ctypes.string_at(pointer))
        finally:
            core.tp_core_free(pointer)
        if not response.get('ok'):
            raise RuntimeError(response.get('error'))
        return response['value']

    def measure(operation, samples=40):
        for _ in range(5):
            operation()
        times = []
        for _ in range(samples):
            start = time.perf_counter_ns()
            operation()
            times.append((time.perf_counter_ns() - start) / 1e6)
        times.sort()
        return dict(median_ms=statistics.median(times),
                    p95_ms=times[math.ceil(len(times) * .95) - 1], max_ms=max(times))

    with tempfile.TemporaryDirectory(prefix='termpilot-core-benchmark-') as directory:
        call(dict(method='sync.prepare', directory=directory))
        host = dict(id='AC8BFA63-BB4B-4EB7-AC41-FF23B49356E0', label='Fixture',
                    hostname='fixture.invalid', port=22, username='fixture', authentication='agent')
        request = dict(method='sync.checkConnection', directory=directory, host=host)
        results = {'connection_policy_check': measure(lambda: call(request))}
        started = threading.Event()
        errors = []

        def writer():
            try:
                with sqlite3.connect(str(Path(directory) / 'vault.sqlite')) as db:
                    db.execute('BEGIN IMMEDIATE')
                    started.set()
                    time.sleep(.3)
                    db.rollback()
            except Exception as error:
                errors.append(str(error))
                started.set()

        thread = threading.Thread(target=writer)
        thread.start()
        if not started.wait(2) or errors:
            raise RuntimeError(errors or 'Writer did not start')
        start = time.perf_counter_ns()
        call(request)
        results['policy_check_during_300ms_wal_write_ms'] = (time.perf_counter_ns() - start) / 1e6
        thread.join()
        if errors:
            raise RuntimeError(errors)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(results, indent=2) + '\n')
    print(json.dumps(results))


if __name__ == '__main__':
    main()
