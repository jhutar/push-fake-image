#!/usr/bin/env python3
# -*- coding: UTF-8 -*-

import argparse
import csv
import datetime
import logging
import logging.handlers
import requests
import signal
import sys
import time
import urllib3


def setup_logger(stderr_log_lvl):
    """
    Create logger that logs to both stderr and log file but with different log level
    """
    # Remove all handlers from root logger if any
    logging.basicConfig(level=logging.NOTSET, handlers=[])
    # Change root logger level from WARNING (default) to NOTSET in order for all messages to be delegated.
    logging.getLogger().setLevel(logging.NOTSET)

    # Log message format
    formatter = logging.Formatter(
        "%(asctime)s %(name)s %(processName)s %(threadName)s %(levelname)s %(message)s"
    )
    formatter.converter = time.gmtime

    # Add stderr handler, with level INFO
    console = logging.StreamHandler()
    console.setFormatter(formatter)
    console.setLevel(stderr_log_lvl)
    logging.getLogger("root").addHandler(console)

    # Add file rotating handler, with level DEBUG
    rotating_handler = logging.handlers.RotatingFileHandler(
        filename="/tmp/measure-signed.log",
        maxBytes=100 * 1000,
        backupCount=2,
    )
    rotating_handler.setLevel(logging.DEBUG)
    rotating_handler.setFormatter(formatter)
    logging.getLogger().addHandler(rotating_handler)

    return logging.getLogger("root")


def sigterm_handler(_signo, _stack_frame):
    logging.debug(f"Detected signal {_signo}")
    sys.exit(0)   # Raises SystemExit(0):


def parsedate(string):
    try:
        return datetime.datetime.fromisoformat(string)
    except AttributeError:
        out = datetime.datetime.strptime(string, "%Y-%m-%dT%H:%M:%SZ")
        out = out.replace(tzinfo=datetime.timezone.utc)
        return out


def main():
    parser = argparse.ArgumentParser(
        prog="Count signed TaskRuns",
        description="Measure number of signed Tekton TaskRuns and time needed to do so",
    )
    parser.add_argument(
        "--delay",
        help="How many seconds to wait between measurements",
        default=5,
        type=float,
    )
    parser.add_argument(
        "--server",
        help="Kubernetes API server to talk to",
        required=True,
        type=str,
    )
    parser.add_argument(
        "--namespace",
        help="Namespace to read TaskRuns from",
        required=True,
        type=str,
    )
    parser.add_argument(
        "--token",
        help="Authorization Bearer token",
        required=True,
        type=str,
    )
    parser.add_argument(
        "--insecure",
        help="Ignore SSL thingy",
        action="store_true",
    )
    parser.add_argument(
        "--save",
        help="Save ",
        default="/tmp/measure-signed.csv",
        type=str,
    )
    parser.add_argument(
        "-v",
        "--verbose",
        help="Verbose output",
        action="store_true",
    )
    parser.add_argument(
        "-d",
        "--debug",
        help="Debug output",
        action="store_true",
    )
    args = parser.parse_args()

    if args.debug:
        logger = setup_logger(logging.DEBUG)
    elif args.verbose:
        logger = setup_logger(logging.INFO)
    else:
        logger = setup_logger(logging.WARNING)

    logger.debug(f"Args: {args}")

    signal.signal(signal.SIGTERM, sigterm_handler)

    session = requests.Session()
    url = f"{args.server}/apis/tekton.dev/v1/namespaces/{args.namespace}/taskruns"
    headers = {
        "Authorization": f"Bearer {args.token}",
        "Accept": "application/json;as=Table;g=meta.k8s.io;v=v1",
        "Accept-Encoding": "gzip",
    }
    verify = not args.insecure

    if args.insecure:
        urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

    with open(args.save, "w") as fd:
        csv_writer = csv.writer(fd)
        csv_writer.writerow(["date", "all", "succeeded", "signed", "unsigned", "guessed avg", "guessed from count"])

    try:
        while True:
            if "UTC" in dir(datetime):
                now = datetime.datetime.now(datetime.UTC)
            else:
                now = datetime.datetime.utcnow().replace(tzinfo=datetime.timezone.utc)

            response = session.get(url, headers=headers, verify=verify, timeout=100)
            response.raise_for_status()
            data = response.json()
            logging.debug(f"Obtained {len(response.content)} bytes of data with {response.status_code} status code")
            # with open("../openshift-pipelines_performance/taskruns-table.json", "r") as fd:
            #     data = json.load(fd)

            taskruns_all = 0
            taskruns_succeeded = 0
            taskruns_signed = 0
            taskruns_sig_duration = []

            for row in data["rows"]:
                taskruns_all += 1
                if row["cells"][2] == "Succeeded" and row["cells"][1] == "True":
                    taskruns_succeeded += 1
                if "annotations" in row["object"]["metadata"] and "chains.tekton.dev/signed" in row["object"]["metadata"]["annotations"] and row["object"]["metadata"]["annotations"]["chains.tekton.dev/signed"] == "true":
                    taskruns_signed += 1

                    # Guess signing duration
                    completed_time = None
                    signed_time = None
                    for item in row["object"]["metadata"]["managedFields"]:
                        if item["manager"] == "openshift-pipelines-controller" \
                           and "f:status" in item["fieldsV1"] \
                           and "f:completionTime" in item["fieldsV1"]["f:status"]:
                            completed_time = parsedate(item["time"])
                        if item["manager"] == "openshift-pipelines-chains-controller" \
                           and "f:metadata" in item["fieldsV1"] \
                           and "f:annotations" in item["fieldsV1"]["f:metadata"] \
                           and "f:chains.tekton.dev/signed" in item["fieldsV1"]["f:metadata"]["f:annotations"]:
                            signed_time = parsedate(item["time"])
                    if completed_time is not None and signed_time is not None:
                        taskruns_sig_duration.append((signed_time - completed_time).total_seconds())

            taskruns_sig_avg = 0
            if len(taskruns_sig_duration) > 0:
                taskruns_sig_avg = sum(taskruns_sig_duration) / len(taskruns_sig_duration)

            logger.info(f"Status as of {now.isoformat()}: all={taskruns_all}, succeeded={taskruns_succeeded}, signed={taskruns_signed}, guessed avg duration={taskruns_sig_avg:.02f} out of {len(taskruns_sig_duration)}")

            with open(args.save, "a") as fd:
                csv_writer = csv.writer(fd)
                csv_writer.writerow([now.isoformat(), taskruns_all, taskruns_succeeded, taskruns_signed, taskruns_succeeded - taskruns_signed, taskruns_sig_avg, len(taskruns_sig_duration)])

            time.sleep(args.delay)
    finally:
        print("Goodbye")


if __name__ == "__main__":
    sys.exit(main())
