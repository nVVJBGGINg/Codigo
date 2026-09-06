Parte 01

from __future__ import annotations

import locust
from locust.opentelemetry import setup_opentelemetry

import atexit
import errno
import gc
import inspect
import itertools
import logging
import os
import signal
import sys
import time
import traceback
import webbrowser
from typing import TYPE_CHECKING

import gevent

from . import log, stats
from .argument_parser import (
    get_locustfiles_locally,
    get_parser,
    parse_locustfile_option,
)
from .env import Environment
from .html import get_html_report, process_html_filename
from .input_events import input_listener
from .log import greenlet_exception_logger, setup_logging
from .user.inspectuser import print_task_ratio, print_task_ratio_json
from .util.load_locustfile import load_locustfile, load_locustfile_pytest

# import external plugins if  installed to allow for registering custom arguments etc
try:
    import locust_plugins  # pyright: ignore[reportMissingImports] # noqa: F401
except ModuleNotFoundError as e:
    if e.msg != "No module named 'locust_plugins'":
        raise

if TYPE_CHECKING:
    from collections.abc import Callable

version = locust.__version__

# Options to ignore when using a custom shape class without `use_common_options=True`
# See: https://docs.locust.io/en/stable/custom-load-shape.html#use-common-options
COMMON_OPTIONS = {
    "num_users": "users",
    "spawn_rate": "spawn-rate",
    "run_time": "run-time",
}


def create_environment(
    user_classes,
    options,
    events=None,
    shape_class=None,
    locustfile=None,
    parsed_locustfiles=None,
    available_user_classes=None,
    available_shape_classes=None,
    available_user_tasks=None,
):
    """
    Create an Environment instance from options
    """
    return Environment(
        locustfile=locustfile,
        user_classes=user_classes,
        shape_class=shape_class,
        events=events,
        host=options.host,
        reset_stats=options.reset_stats,
        parsed_options=options,
        parsed_locustfiles=parsed_locustfiles,
        available_user_classes=available_user_classes,
        available_shape_classes=available_shape_classes,
        available_user_tasks=available_user_tasks,
        profile=options.profile,
    )


def merge_locustfiles_content(
    locustfiles: list[str],
) -> tuple[
    dict[str, type[locust.User]],
    dict[str, locust.LoadTestShape],
    dict[str, list[locust.TaskSet | Callable]],
    locust.LoadTestShape | None,
]:
    """
    Validate content of each locustfile in locustfiles and merge data to single objects output.

    Can stop locust execution on errors.
    """
    available_user_classes: dict[str, type[locust.User]] = {}
    available_shape_classes: dict[str, locust.LoadTestShape] = {}
    # TODO: list[locust.TaskSet | Callable] should be replaced with correct type,
    #  supported by User class task attribute. This require additional rewrite,
    #  out of main refactoring.
    #  Check docs for real supported task attribute signature for User\TaskSet class.
    available_user_tasks: dict[str, list[locust.TaskSet | Callable]] = {}

    def set_available_things(user_classes, shape_classes):
        # Setting Available Shape Classes
        for _shape_class in shape_classes:
            shape_class_name = type(_shape_class).__name__
            if shape_class_name in available_shape_classes.keys():
                sys.stderr.write(f"Duplicate shape classes: {shape_class_name}\n")
                sys.exit(1)

            available_shape_classes[shape_class_name] = _shape_class

        # Setting Available User Classes
        for class_name, class_definition in user_classes.items():
            if class_name in available_user_classes.keys():
                previous_path = inspect.getfile(available_user_classes[class_name])
                new_path = inspect.getfile(class_definition)
                if previous_path == new_path:
                    # The same User class was defined in two locustfiles but one probably imported the other, so we just ignore it
                    continue
                else:
                    sys.stderr.write(
                        f"Duplicate user class names: {class_name} is defined in both {previous_path} and {new_path}\n"
                    )
                    sys.exit(1)

            available_user_classes[class_name] = class_definition
            available_user_tasks[class_name] = class_definition.tasks

    for _locustfile in locustfiles:
        user_classes, shape_classes = load_locustfile(_locustfile)
        set_available_things(user_classes, shape_classes)

    if not available_user_classes:  # only load pytest-based locustfiles if no regular ones were found
        for _locustfile in locustfiles:
            user_classes = load_locustfile_pytest(_locustfile)
            set_available_things(user_classes, [])

    shape_class = list(available_shape_classes.values())[0] if available_shape_classes else None

    return available_user_classes, available_shape_classes, available_user_tasks, shape_class


def main():
    # find specified locustfile(s) and make sure it exists, using a very simplified
    # command line parser that is only used to parse the -f option.
    options = parse_locustfile_option()

    locustfiles = get_locustfiles_locally(options)

    # Importing Locustfile(s) - setting available UserClasses and ShapeClasses to choose from in UI
    (
        available_user_classes,
        available_shape_classes,
        available_user_tasks,
        shape_class,
    ) = merge_locustfiles_content(locustfiles)

    # parse all command line options
    parser = get_parser()
    options = parser.parse_args()

    if options.stats_history_enabled and (options.csv_prefix is None):
        parser.error("'--csv-full-history' requires '--csv'.")

    stats.validate_stats_configuration()

    if options.headful:
        options.headless = False

    if options.autoquit != -1 and not options.autostart:
        sys.stderr.write("--autoquit is only meaningful in combination with --autostart\n")
        sys.exit(1)

    # setup logging
    if not options.skip_log_setup:
        setup_logging(options.loglevel, options.logfile)

    start_message = f"Starting Locust {version}"

    if options.otel:
        if setup_opentelemetry(options.locustfile, options.profile):
            start_message += ", OpenTelemetry enabled"

    children = []
    logger = logging.getLogger(__name__)

    logger.info(start_message)

    if options.processes:
        if os.name == "nt":
            sys.stderr.write("--processes is not supported in Windows (except in WSL)\n")
            sys.exit(1)
        if options.processes == -1:
            options.processes = os.cpu_count()
            if not options.processes:
                sys.stderr.write("--processes failed to detect number of cpus!?\n")
                sys.exit(1)
        elif options.processes < -1:
            sys.stderr.write(f"Invalid --processes count {options.processes}\n")
            sys.exit(1)
        elif options.master:
            sys.stderr.write(
                "--master cannot be combined with --processes. Remove --master, as it is implicit as long as --worker is not set.\n"
            )
            sys.exit(1)
        # Optimize copy-on-write-behavior to save some memory (aprx 26MB -> 15MB rss) in child processes
        gc.collect()  # avoid freezing garbage
        if hasattr(gc, "freeze"):
            gc.freeze()  # move all objects to perm gen so ref counts dont get updated
        for _ in range(options.processes):
            if child_pid := gevent.fork():
                children.append(child_pid)
                logging.debug(f"Started child worker with pid #{child_pid}")
            else:
                # child is always a worker, even when it wasn't set on command line
                options.worker = True
                # remove options that dont make sense on worker
                options.run_time = None
                options.autostart = None
                options.csv_prefix = None
                options.stats_history_enabled = False
                options.html_file = None
                options.print_stats = None
                break
        else:
            # we're in the parent process
            if options.worker:
                # ignore the first sigint in parent, and wait for the children to handle sigint
                def sigint_handler(_signal, _frame):
                    if getattr(sigint_handler, "has_run", False):
                        # if parent gets repeated sigint, we kill the children hard
                        for child_pid in children:
                            try:
                                logging.debug(f"Sending SIGKILL to child with pid {child_pid}")
                                os.kill(child_pid, signal.SIGKILL)
                            except ProcessLookupError:
                                pass  # process already dead
                            except Exception:
                                logging.error(traceback.format_exc())
                        sys.exit(1)
                    sigint_handler.has_run = True

                signal.signal(signal.SIGINT, sigint_handler)
                exit_code = 0
                # nothing more to do, just wait for the children to exit
                for child_pid in children:
                    _, child_status = os.waitpid(child_pid, 0)
                    child_exit_code = os.waitstatus_to_exitcode(child_status)
                    exit_code = max(exit_code, child_exit_code)
                sys.exit(exit_code)
            else:
                options.master = True
                options.expect_workers = options.processes

                def kill_workers(children):
                    exit_code = 0
                    start_time = time.time()
                    # give children some time to finish up (in case they had an error parsing arguments etc)
                    for child_pid in children[:]:
                        while time.time() < start_time + 3:
                            try:
                                _, child_status = os.waitpid(child_pid, os.WNOHANG)
                                children.remove(child_pid)
                                child_exit_code = os.waitstatus_to_exitcode(child_status)
                                exit_code = max(exit_code, child_exit_code)
                            except OSError as e:
                                if e.errno == errno.EINTR:
                                    time.sleep(0.1)
                                else:
                                    logging.error(traceback.format_exc())
                            else:
                                break
                    for child_pid in children:
                        try:
                            logging.debug(f"Sending SIGINT to child with pid {child_pid}")
                            os.kill(child_pid, signal.SIGINT)
                        except ProcessLookupError:
                            pass  # never mind, process was already dead
                    for child_pid in children:
                        _, child_status = os.waitpid(child_pid, 0)
                        child_exit_code = os.waitstatus_to_exitcode(child_status)
                        exit_code = max(exit_code, child_exit_code)
                    if exit_code > 1:
                        logging.error(f"Bad response code from worker children: {exit_code}")
                    # ensure master doesn't finish until output from workers has arrived
                    # otherwise the terminal might look weird.
                    time.sleep(0.1)

                atexit.register(kill_workers, children)

    greenlet_exception_handler = greenlet_exception_logger(logger)

    if options.list_commands:
        print("Available Users:")
        for name in available_user_classes:
            print("    " + name)
        sys.exit(0)

    if not available_user_classes:
        logger.error("No User class found!")
        sys.exit(1)

    # make sure specified User exists
    if options.user_classes:
        if missing := set(options.user_classes) - set(available_user_classes.keys()):
            logger.error(f"Unknown User(s): {', '.join(missing)}\n")
            sys.exit(1)
        else:
            names = set(options.user_classes) & set(available_user_classes.keys())
            user_classes = [available_user_classes[n] for n in names]
    else:
        # list() call is needed to consume the dict_view object in Python 3
        user_classes = list(available_user_classes.values())

    if not shape_class and options.num_users:
        fixed_count_total = sum([user_class.fixed_count for user_class in user_classes])
        if fixed_count_total > options.num_users:
            logger.info(
                f"Total fixed_count of User classes ({fixed_count_total}) is greater than the specified number of users ({options.num_users}), so not all will be spawned."
            )

    if os.name != "nt":
        minimum_open_file_limit = 10000
        soft_limit = None
        try:
            import resource

            (soft_limit, hard_limit) = resource.getrlimit(resource.RLIMIT_NOFILE)

            if soft_limit < minimum_open_file_limit:
                # Increasing the limit to 10000 within a running process should work on at least MacOS.
                # It does not work on all OS:es, but we should be no worse off for trying.
                limits = minimum_open_file_limit, hard_limit
                resource.setrlimit(resource.RLIMIT_NOFILE, limits)
        except Exception:
            logger.warning(
                f"""System open file limit '{soft_limit}' is below minimum setting '{minimum_open_file_limit}'.
It's not high enough for load testing, and the OS didn't allow locust to increase it by itself.
See https://github.com/locustio/locust/wiki/Installation#increasing-maximum-number-of-open-files-limit for more info."""
            )

    # At least one locust file exists, or system will exit earlier
    locustfile_path = os.path.basename(locustfiles[0])

    # create locust Environment
    environment = create_environment(
        user_classes,
        options,
        events=locust.events,
        shape_class=shape_class,
        locustfile=locustfile_path,
        parsed_locustfiles=locustfiles,
        available_user_classes=available_user_classes,
        available_shape_classes=available_shape_classes,
        available_user_tasks=available_user_tasks,
    )

    if options.config_users:
        try:
            for user_config in itertools.chain(*options.config_users):
                environment.update_user_class(user_config)
        except KeyError as e:
            logger.error(
                f"Error applying user config, probably you tried to specify config for a User not present in your locustfile: {e}"
            )
            sys.exit(-1)
        except Exception as e:
            logger.exception(e)
            sys.exit(-1)

    if (
        shape_class
        and not shape_class.use_common_options
        and any(getattr(options, opt, None) for opt in COMMON_OPTIONS)
    ):
        logger.warning(
            "--run-time, --users or --spawn-rate have no impact on LoadShapes unless the shape class explicitly reads them. "
            "See: docs.locust.io/en/stable/custom-load-shape.html#use-common-options"
        )
        ignored = [f"--{arg}" for opt, arg in COMMON_OPTIONS.items() if getattr(options, opt, None)]
        logger.warning(f"The following option(s) will be ignored: {', '.join(ignored)}")

    if options.show_task_ratio:
        print("\n Task ratio per User class")
        print("-" * 80)
        print_task_ratio(user_classes, options.num_users, False)
        print("\n Total task ratio")
        print("-" * 80)
        print_task_ratio(user_classes, options.num_users, True)
        sys.exit(0)
    if options.show_task_ratio_json:
        print_task_ratio_json(user_classes, options.num_users)
        sys.exit(0)

    if options.master:
        if options.worker:
            logger.error("The --master argument cannot be combined with --worker")
            sys.exit(-1)
        if options.expect_workers < 1:
            logger.error(f"Invalid --expect-workers argument ({options.expect_workers}), must be a positive number")
            sys.exit(-1)
        runner = environment.create_master_runner(
            master_bind_host=options.master_bind_host,
            master_bind_port=options.master_bind_port,
        )
    elif options.worker:
        try:
            runner = environment.create_worker_runner(options.master_host, options.master_port)
            logger.debug(
                "Connected to locust master: %s:%s%s", options.master_host, options.master_port, options.web_base_path
            )
        except OSError as e:
            logger.error("Failed to connect to the Locust master: %s", e)
            sys.exit(-1)
    else:
        runner = environment.create_local_runner()

    # main_greenlet is pointing to runners.greenlet by default, it will point the web greenlet later if in web mode
    main_greenlet = runner.greenlet

    if options.run_time:
        if options.worker:
            logger.debug("--run-time specified for a worker node will be ignored.")

    if options.csv_prefix:
        base_csv_file = os.path.basename(options.csv_prefix)
        base_csv_dir = options.csv_prefix[: -len(base_csv_file)]
        if not os.path.exists(base_csv_dir) and len(base_csv_dir) != 0:
            os.makedirs(base_csv_dir)
        stats_csv_writer = stats.StatsCSVFileWriter(
            environment, stats.PERCENTILES_TO_REPORT, options.csv_prefix, options.stats_history_enabled
        )
    else:
        stats_csv_writer = stats.StatsCSV(environment, stats.PERCENTILES_TO_REPORT)

    url = None
    # start Web UI
    if not options.headless and not options.worker:
        protocol = "https" if options.tls_cert and options.tls_key else "http"

        if options.web_base_path and options.web_base_path[0] != "/":
            logger.error(
                f"Invalid format for --web-base-path argument ({options.web_base_path}): the url path must start with a slash."
            )
            sys.exit(1)
        if options.web_host == "*":
            # special check for "*" so that we're consistent with --master-bind-host
            web_host = ""
        else:
            web_host = options.web_host
        if web_host:
            url = f"{protocol}://{web_host}:{options.web_port}{options.web_base_path}"
        elif options.web_host_display_name:
            url = f"{options.web_host_display_name}"
        else:
            url = f"{protocol}://{'localhost' if os.name == 'nt' else '0.0.0.0'}:{options.web_port}{options.web_base_path}"
        logger.info(f"Starting web interface at {url}, press enter to open your default browser.")

        web_ui = environment.create_web_ui(
            host=web_host,
            port=options.web_port,
            web_base_path=options.web_base_path,
            web_login=options.web_login,
            tls_cert=options.tls_cert,
            tls_key=options.tls_key,
            stats_csv_writer=stats_csv_writer,
            delayed_start=True,
            userclass_picker_is_active=options.class_picker,
            build_path=options.build_path,
        )
    else:
        web_ui = None

    if options.autostart and options.headless:
        logger.info("The --autostart argument is implied by --headless, no need to set both.")

    if options.autostart and options.worker:
        logger.debug("The --autostart argument has no meaning on a worker.")

    def assign_equal_weights(environment, **kwargs):
        environment.assign_equal_weights()

    if options.equal_weights:
        environment.events.init.add_listener(assign_equal_weights)

    # Fire locust init event which can be used by end-users' code to run setup code that
    # need access to the Environment, Runner or WebUI.
    environment.events.init.fire(environment=environment, runner=runner, web_ui=web_ui)
    if log.unhandled_greenlet_exception:
        # treat exceptions in init handlers as fatal. They are already logged so no need to log anything more.
        sys.exit(1)

    if web_ui:
        web_ui.start()
        main_greenlet = web_ui.greenlet


    def stop_and_optionally_quit(reason="--run-time limit reached"):
        if options.autostart and not options.headless:
            logger.info(f"{reason}, stopping test")
            runner.stop()
            if options.autoquit != -1:
                logger.debug(f"Autoquit time limit set to {options.autoquit} seconds")
                time.sleep(options.autoquit)
                logger.info("--autoquit time reached, shutting down")
                runner.quit()
                if web_ui:
                    web_ui.stop()
            else:
                logger.info("--autoquit not specified, leaving web ui running indefinitely")
        else:  # --headless run
            logger.info(f"{reason}, shutting down")
            runner.quit()

    def spawn_run_time_quit_greenlet():
        gevent.spawn_later(options.run_time, stop_and_optionally_quit).link_exception(greenlet_exception_handler)

    headless_master_greenlet = None
    stats_printer_greenlet = None
    if not options.only_summary and (options.print_stats or (options.headless and not options.worker)):
        # spawn stats printing greenlet
        stats_printer_greenlet = gevent.spawn(stats.stats_printer(runner.stats))
        stats_printer_greenlet.link_exception(greenlet_exception_handler)

    gevent.spawn(stats.stats_history, runner)

    def start_automatic_run():
        if options.master:
            # wait for worker nodes to connect
            start_time = time.monotonic()
            while len(runner.clients.ready) < options.expect_workers:
                if options.expect_workers_max_wait and options.expect_workers_max_wait < time.monotonic() - start_time:
                    logger.error("Gave up waiting for workers to connect")
                    runner.quit()
                    sys.exit(1)
                if time.monotonic() - start_time > 5:
                    logging.info(
                        "Waiting for workers to be ready, %s of %s connected",
                        len(runner.clients.ready),
                        options.expect_workers,
                    )
                else:
                    logging.debug(
                        "Waiting for workers to be ready, %s of %s connected",
                        len(runner.clients.ready),
                        options.expect_workers,
                    )
                # TODO: Handle KeyboardInterrupt and send quit signal to workers that are started.
                #       Right now, if the user sends a ctrl+c, the master will not gracefully
                #       shutdown resulting in all the already started workers to stay active.
                time.sleep(1)
        if not options.worker:
            # apply headless mode defaults
            if options.num_users is None:
                options.num_users = 1
            if options.spawn_rate is None:
                options.spawn_rate = 1

            # start the test
            if environment.shape_class:
                try:
                    environment.runner.start_shape()
                    environment.runner.shape_greenlet.join()
                except KeyboardInterrupt:
                    logging.info("Exiting due to CTRL+C interruption")
                finally:
                    stop_and_optionally_quit(reason="Shape test completed")
            else:
                headless_master_greenlet = gevent.spawn(runner.start, options.num_users, options.spawn_rate)
                headless_master_greenlet.link_exception(greenlet_exception_handler)

            if options.run_time:
                logger.info(f"Run time limit set to {options.run_time} seconds")
                spawn_run_time_quit_greenlet()
            elif not environment.shape_class:
                logger.info("No run time limit set, use CTRL+C to interrupt")

    if options.csv_prefix:
        gevent.spawn(stats_csv_writer.stats_writer).link_exception(greenlet_exception_handler)

    if options.headless:
        start_automatic_run()

    input_listener_greenlet = None
    if not options.worker:
        # spawn input listener greenlet
        input_listener_greenlet = gevent.spawn(
            input_listener(
                {
                    "w": lambda: (
                        runner.start(runner.user_count + 1, 100)
                        if runner.state != "spawning"
                        else logging.warning("Already spawning users, can't spawn more right now")
                    ),
                    "W": lambda: (
                        runner.start(runner.user_count + 10, 100)
                        if runner.state != "spawning"
                        else logging.warning("Already spawning users, can't spawn more right now")
                    ),
                    "s": lambda: (
                        runner.start(max(0, runner.user_count - 1), 100)
                        if runner.state != "spawning"
                        else logging.warning("Spawning users, can't stop right now")
                    ),
                    "S": lambda: (
                        runner.start(max(0, runner.user_count - 10), 100)
                        if runner.state != "spawning"
                        else logging.warning("Spawning users, can't stop right now")
                    ),
                    "\r": lambda: webbrowser.open_new_tab(url) if url else None,
                    "\n": lambda: webbrowser.open_new_tab(url) if url else None,
                },
            )
        )
        input_listener_greenlet.link_exception(greenlet_exception_handler)
        # ensure terminal is reset, even if there is an unhandled exception in locust or someone
        # does something wild, like calling sys.exit() in the locustfile
        atexit.register(input_listener_greenlet.kill, block=True)

    def shutdown():
        """
        Shut down locust by firing quitting event, printing/writing stats and exiting
        """
        logger.debug("Running teardowns...")

        if input_listener_greenlet is not None:
            input_listener_greenlet.kill(block=False)

        environment.events.quitting.fire(environment=environment, reverse=True)

        # determine the process exit code
        if environment.process_exit_code is not None:
            code = environment.process_exit_code
        elif len(runner.errors) or len(runner.exceptions):
            code = options.exit_code_on_error
        elif log.unhandled_greenlet_exception:
            code = 2
        else:
            code = 0

        logger.info(f"Shutting down (exit code {code})")

        if stats_printer_greenlet is not None:
            stats_printer_greenlet.kill(block=False)
        if headless_master_greenlet is not None:
            headless_master_greenlet.kill(block=False)
        logger.debug("Cleaning up runner...")
        if runner is not None:
            runner.quit()
        if options.json:
            stats.print_stats_json(runner.stats)
        if options.json_file:
            stats.save_stats_json(runner.stats, options.json_file)
        elif not isinstance(runner, locust.runners.WorkerRunner):
            stats.print_stats(runner.stats, current=False)
            stats.print_percentile_stats(runner.stats)
            stats.print_error_report(runner.stats)
        environment.events.quit.fire(exit_code=code)
        if stats_csv_writer is not None:
            stats_csv_writer.close_files()
        sys.exit(code)

    # install SIGTERM handler
    def sig_term_handler():
        logger.info("Got SIGTERM signal")
        shutdown()

    def save_html_report():
        html_report = get_html_report(environment, show_download_link=False)
        process_html_filename(options)
        logger.debug("Writing html report to file: %s", options.html_file)
        with open(options.html_file, "w", encoding="utf-8") as file:
            file.write(html_report)

    gevent.signal_handler(signal.SIGTERM, sig_term_handler)

    try:
        if options.class_picker:
            logger.debug("Locust is running with the UserClass Picker Enabled")
        if options.autostart and not options.headless:
            start_automatic_run()

        main_greenlet.join()
        if options.html_file:
            save_html_report()
    except KeyboardInterrupt:
        if options.html_file:
            save_html_report()
    except Exception:
        raise
    shutdown()


parte 02


from __future__ import annotations

from locust import __version__

import functools
import inspect
import json
import logging
import os
import re
import socket
import sys
import time
import traceback
from abc import abstractmethod
from collections import defaultdict
from collections.abc import Callable, Iterator, MutableMapping, ValuesView
from operator import itemgetter, methodcaller
from types import TracebackType
from typing import TYPE_CHECKING, Any, NoReturn, TypedDict, cast
from uuid import uuid4

import gevent
import greenlet
import psutil
from gevent.event import Event
from gevent.pool import Group

from . import argument_parser
from .dispatch import UsersDispatcher
from .exception import RPCError, RPCReceiveError, RPCSendError, StopTest
from .log import get_logs, greenlet_exception_logger
from .rpc import Message, rpc
from .stats import RequestStats, StatsError, setup_distributed_stats_event_listeners
from .util.directory import get_abspaths_in
from .util.url import is_url

if TYPE_CHECKING:
    from . import User
    from .env import Environment

logger = logging.getLogger(__name__)

STATE_INIT, STATE_SPAWNING, STATE_RUNNING, STATE_CLEANUP, STATE_STOPPING, STATE_STOPPED, STATE_MISSING = [
    "ready",
    "spawning",
    "running",
    "cleanup",
    "stopping",
    "stopped",
    "missing",
]
WORKER_REPORT_INTERVAL = 3.0
WORKER_LOG_REPORT_INTERVAL = 10
CPU_MONITOR_INTERVAL = 10.0
CPU_WARNING_THRESHOLD = 90
HEARTBEAT_INTERVAL = 1
HEARTBEAT_LIVENESS = 3
HEARTBEAT_DEAD_INTERNAL = -60
MASTER_HEARTBEAT_TIMEOUT = 60
FALLBACK_INTERVAL = 5
CONNECT_TIMEOUT = 5
CONNECT_RETRY_COUNT = 60


def locust_exception_handler(environment: Environment):
    exception_logger = greenlet_exception_logger(logger)

    def handler(greenlet):
        if greenlet.exc_info[0] is StopTest:
            logger.error(greenlet.exc_info[1])
            logger.warning("Stopping Locust...")
            if environment.parsed_options.headless:
                environment.runner.quit()
            else:
                environment.runner.stop()
        else:
            exception_logger(greenlet)

    return handler


class ExceptionDict(TypedDict):
    count: int
    msg: str
    traceback: str
    nodes: set[str]


class Runner:
    """
    Orchestrates the load test by starting and stopping the users.

    Use one of the :meth:`create_local_runner <locust.env.Environment.create_local_runner>`,
    :meth:`create_master_runner <locust.env.Environment.create_master_runner>` or
    :meth:`create_worker_runner <locust.env.Environment.create_worker_runner>` methods on
    the :class:`Environment <locust.env.Environment>` instance to create a runner of the
    desired type.
    """

    def __init__(self, environment: Environment) -> None:
        self.environment = environment
        self.user_greenlets = Group()
        self.greenlet = Group()
        self.state = STATE_INIT
        self.spawning_greenlet: gevent.Greenlet | None = None
        self.shape_greenlet: gevent.Greenlet | None = None
        self.shape_last_tick: tuple[int, float] | tuple[int, float, list[type[User]] | None] | None = None
        self.current_cpu_usage: float = 0.0
        self.cpu_warning_emitted: bool = False
        self.worker_cpu_warning_emitted: bool = False
        self.current_memory_usage: int = 0
        self.greenlet.spawn(self.monitor_cpu_and_memory).link_exception(locust_exception_handler(self.environment))
        self.exceptions: dict[int, ExceptionDict] = {}
        # Because of the way the ramp-up/ramp-down is implemented, target_user_classes_count
        # is only updated at the end of the ramp-up/ramp-down.
        # See https://github.com/locustio/locust/issues/1883#issuecomment-919239824 for context.
        self.target_user_classes_count: dict[str, int] = {}
        # target_user_count is set before the ramp-up/ramp-down occurs.
        self.target_user_count: int = 0
        self.custom_messages: dict[str, tuple[Callable, bool]] = {}

        self._users_dispatcher: UsersDispatcher | None = None

        # set up event listeners for recording requests
        def on_request(request_type, name, response_time, response_length, exception=None, **_kwargs):
            self.stats.log_request(request_type, name, response_time, response_length)
            if exception:
                self.stats.log_error(request_type, name, exception)

        self.environment.events.request.add_listener(on_request)

        self.connection_broken = False
        self.final_user_classes_count: dict[str, int] = {}  # just for the ratio report, fills before runner stops

        # register listener that resets stats when spawning is complete
        def on_spawning_complete(user_count: int) -> None:
            self.update_state(STATE_RUNNING)
            if environment.reset_stats:
                logger.info("Resetting stats\n")
                self.stats.reset_all()

        self.environment.events.spawning_complete.add_listener(on_spawning_complete)

    def __del__(self) -> None:
        # don't leave any stray greenlets if runner is removed
        if self.greenlet and len(self.greenlet) > 0:
            self.greenlet.kill(block=False)

    @property
    def user_classes(self) -> list[type[User]]:
        return self.environment.user_classes

    @property
    def user_classes_by_name(self) -> dict[str, type[User]]:
        return self.environment.user_classes_by_name

    @property
    def stats(self) -> RequestStats:
        return self.environment.stats

    @property
    def errors(self) -> dict[str, StatsError]:
        return self.stats.errors

    @property
    def user_count(self) -> int:
        """
        :returns: Number of currently running users
        """
        return len(self.user_greenlets)

    @property
    def user_classes_count(self) -> dict[str, int]:
        """
        :returns: Number of currently running users for each user class
        """
        user_classes_count = {user_class.__name__: 0 for user_class in self.user_classes}
        for user_greenlet in self.user_greenlets:
            try:
                user = user_greenlet.args[0]
            except IndexError:
                # TODO: Find out why args is sometimes empty. In gevent code,
                #       the supplied args are cleared in the gevent.greenlet.Greenlet.__free,
                #       so it seems a good place to start investigating. My suspicion is that
                #       the supplied args are emptied whenever the greenlet is dead, so we can
                #       simply ignore the greenlets with empty args.
                logger.debug(
                    "ERROR: While calculating number of running users, we encountered a user that didn't have proper args %s (user_greenlet.dead=%s)",
                    user_greenlet,
                    user_greenlet.dead,
                )
                continue
            user_classes_count[user.__class__.__name__] += 1
        return user_classes_count

    def update_state(self, new_state: str) -> None:
        """
        Updates the current state
        """
        # I (cyberwiz) commented out this logging, because it is too noisy even for debug level
        # Uncomment it if you are specifically debugging state transitions
        # logger.debug("Updating state to '%s', old state was '%s'" % (new_state, self.state))
        self.state = new_state

    def cpu_log_warning(self) -> bool:
        """Called at the end of the test"""
        if self.cpu_warning_emitted:
            logger.warning(
                "CPU usage was too high at some point during the test! See https://docs.locust.io/en/stable/running-distributed.html for how to distribute the load over multiple CPU cores or machines"
            )
        return self.cpu_warning_emitted

    def spawn_users(self, user_classes_spawn_count: dict[str, int], wait: bool = False):
        if self.state == STATE_INIT or self.state == STATE_STOPPED:
            self.update_state(STATE_SPAWNING)

        logger.debug(
            f"Spawning additional {json.dumps(user_classes_spawn_count)} ({json.dumps(self.user_classes_count)} already running)..."
        )

        def spawn(user_class: str, spawn_count: int) -> list[User]:
            n = 0
            new_users: list[User] = []
            while n < spawn_count:
                new_user = self.user_classes_by_name[user_class](self.environment)
                assert hasattr(new_user, "environment"), (
                    f"Attribute 'environment' is missing on user {user_class}. Perhaps you defined your own __init__ and forgot to call the base constructor? (super().__init__(*args, **kwargs))"
                )
                new_user.start(self.user_greenlets)
                new_users.append(new_user)
                n += 1
                if n % 10 == 0 or n == spawn_count:
                    logger.debug("%i users spawned" % self.user_count)
            logger.debug(f"All users of class {user_class} spawned")
            return new_users

        new_users: list[User] = []
        for user_class, spawn_count in user_classes_spawn_count.items():
            new_users += spawn(user_class, spawn_count)

        if wait:
            self.user_greenlets.join()
            logger.info("All users stopped\n")
        return new_users

    def stop_users(self, user_classes_stop_count: dict[str, int]) -> None:
        async_calls_to_stop = Group()
        stop_group = Group()

        for user_class, stop_count in user_classes_stop_count.items():
            if self.user_classes_count[user_class] == 0:
                continue

            to_stop: list[greenlet.greenlet] = []
            for user_greenlet in self.user_greenlets:
                if len(to_stop) == stop_count:
                    break
                try:
                    user = user_greenlet.args[0]
                except IndexError:
                    logger.error(
                        "While stopping users, we encountered a user that didn't have proper args %s", user_greenlet
                    )
                    continue
                if type(user) is self.user_classes_by_name[user_class]:
                    to_stop.append(user)

            if not to_stop:
                continue

            while True:
                user_to_stop: User = to_stop.pop()
                logger.debug(f"Stopping {user_to_stop.greenlet.name}")
                if user_to_stop.greenlet is greenlet.getcurrent():
                    # User called runner.quit(), so don't block waiting for killing to finish
                    user_to_stop.group.killone(user_to_stop.greenlet, block=False)
                elif self.environment.stop_timeout:
                    async_calls_to_stop.add(gevent.spawn_later(0, user_to_stop.stop, force=False))
                    stop_group.add(user_to_stop.greenlet)
                else:
                    async_calls_to_stop.add(gevent.spawn_later(0, user_to_stop.stop, force=True))
                if not to_stop:
                    break

        async_calls_to_stop.join()

        if not stop_group.join(timeout=self.environment.stop_timeout):
            logger.info(
                f"Not all users finished their tasks & terminated in {self.environment.stop_timeout} seconds. Stopping them..."
            )
            stop_group.kill(block=True)

        logger.debug(
            "%g users have been stopped, %g still running", sum(user_classes_stop_count.values()), self.user_count
        )

    def monitor_cpu_and_memory(self) -> NoReturn:
        process = psutil.Process()
        while True:
            gevent.sleep(CPU_MONITOR_INTERVAL)
            self.current_cpu_usage = process.cpu_percent()
            self.current_memory_usage = process.memory_info().rss
            if self.current_cpu_usage > CPU_WARNING_THRESHOLD:
                self.environment.events.cpu_warning.fire(environment=self.environment, cpu_usage=self.current_cpu_usage)
                if not self.cpu_warning_emitted:
                    logging.warning(
                        f"CPU usage above {CPU_WARNING_THRESHOLD}%! This may constrain your throughput and may even give inconsistent response time measurements! See https://docs.locust.io/en/stable/running-distributed.html for how to distribute the load over multiple CPU cores or machines"
                    )
                    self.cpu_warning_emitted = True

            self.environment.events.usage_monitor.fire(
                environment=self.environment, cpu_usage=self.current_cpu_usage, memory_usage=self.current_memory_usage
            )

    @abstractmethod
    def start(
        self, user_count: int, spawn_rate: float, wait: bool = False, user_classes: list[type[User]] | None = None
    ) -> None: ...

    @abstractmethod
    def send_message(self, msg_type: str, data: Any = None, client_id: str | None = None) -> None: ...

    def start_shape(self) -> None:
        """
        Start running a load test with a custom LoadTestShape specified in the :meth:`Environment.shape_class <locust.env.Environment.shape_class>` parameter.
        """
        if self.shape_greenlet:
            logger.info("There is an ongoing shape test running. Editing is disabled")
            return

        logger.info("Shape test starting.")
        self.update_state(STATE_INIT)
        self.shape_greenlet = self.greenlet.spawn(self.shape_worker)
        self.shape_greenlet.link_exception(locust_exception_handler(self.environment))
        if self.environment.shape_class is not None:
            self.environment.shape_class.reset_time()

    def shape_worker(self) -> None:
        logger.info("Shape worker starting")
        while self.state == STATE_INIT or self.state == STATE_SPAWNING or self.state == STATE_RUNNING:
            shape_adjustment_start = time.time()
            current_tick = self.environment.shape_class.tick() if self.environment.shape_class is not None else None
            if current_tick is None:
                logger.info("Shape test stopping")
                if self.environment.parsed_options and self.environment.parsed_options.headless:
                    self.quit()
                else:
                    self.stop()
                self.shape_greenlet = None
                self.shape_last_tick = None
                return
            elif self.shape_last_tick != current_tick:
                if len(current_tick) == 2:
                    user_count, spawn_rate = current_tick
                    user_classes = None
                else:
                    user_count, spawn_rate, user_classes = current_tick
                logger.info("Shape test updating to %d users at %.2f spawn rate" % (user_count, spawn_rate))
                # TODO: This `self.start()` call is blocking until the ramp-up is completed. This can leads
                #       to unexpected behaviours such as the one in the following example:
                #       A load test shape has the following stages:
                #           stage 1: (user_count=100, spawn_rate=1) for t < 50s
                #           stage 2: (user_count=120, spawn_rate=1) for t < 100s
                #           stage 3: (user_count=130, spawn_rate=1) for t < 120s
                #        Because the first stage will take 100s to complete, the second stage
                #        will be skipped completely because the shape worker will be blocked
                #        at the `self.start()` of the first stage.
                #        Of course, this isn't a problem if the load test shape is well-defined.
                #        We should probably use a `gevent.timeout` with a duration a little over
                #        `(user_count - prev_user_count) / spawn_rate` in order to limit the runtime
                #        of each load test shape stage.
                self.start(user_count=user_count, spawn_rate=spawn_rate, user_classes=user_classes)
                self.shape_last_tick = current_tick
            shape_adjustment_time_ms = time.time() - shape_adjustment_start
            gevent.sleep(max(1 - shape_adjustment_time_ms, 0))

    def stop(self) -> None:
        """
        Stop a running load test by stopping all running users
        """
        if self.state == STATE_STOPPED:
            return
        try:
            caller = inspect.getframeinfo(inspect.stack()[1][0])
            logger.debug(f"Stopping all users (called from {caller.filename}:{caller.lineno})")
        except Exception:
            logger.debug("Stopping all users (couldn't determine where stop() was called from)")
        self.environment.events.test_stopping.fire(environment=self.environment)
        self.final_user_classes_count = {**self.user_classes_count}
        self.update_state(STATE_CLEANUP)

        # if we are currently spawning users we need to kill the spawning greenlet first
        if self.spawning_greenlet and not self.spawning_greenlet.ready():
            self.spawning_greenlet.kill(block=True)

        if self.environment.shape_class is not None and self.shape_greenlet is not greenlet.getcurrent():
            # If the test was not started yet and locust is
            # stopped/quit, shape_greenlet will be None.
            if self.shape_greenlet is not None:
                self.shape_greenlet.kill(block=True)
                self.shape_greenlet = None
            self.shape_last_tick = None

        self.stop_users(self.user_classes_count)

        self._users_dispatcher = None

        self.update_state(STATE_STOPPED)

        self.cpu_log_warning()
        self.environment.events.test_stop.fire(environment=self.environment)

    def quit(self) -> None:
        """
        Stop any running load test and kill all greenlets for the runner
        """
        self.stop()
        self.greenlet.kill(block=True)

    def log_exception(self, node_id: str, msg: str, formatted_tb: str) -> None:
        key = hash(formatted_tb)
        row = self.exceptions.setdefault(key, {"count": 0, "msg": msg, "traceback": formatted_tb, "nodes": set()})
        row["count"] += 1
        row["nodes"].add(node_id)
        self.exceptions[key] = row

    def register_message(self, msg_type: str, listener: Callable, concurrent=False) -> None:
        """
        Register a listener for a custom message from another node

        :param msg_type: The type of the message to listen for
        :param listener: The function to execute when the message is received
        """
        if msg_type in self.custom_messages:
            raise Exception(f"Tried to register listener method for {msg_type}, but it already had a listener!")
        self.custom_messages[msg_type] = (listener, concurrent)


class LocalRunner(Runner):
    """
    Runner for running single process load test
    """

    def __init__(self, environment) -> None:
        """
        :param environment: Environment instance
        """
        super().__init__(environment)
        # These attributes dont make a lot of sense for LocalRunner
        # but it makes it easier to write tests that work for both local and distributed runs
        self.worker_index = 0
        self.client_id = socket.gethostname() + "_" + uuid4().hex
        self.worker_count = 1
        # Only when running in standalone mode (non-distributed)
        self._local_worker_node = WorkerNode(id="local")
        self._local_worker_node.user_classes_count = self.user_classes_count

        # register listener that's logs the exception for the local runner
        def on_user_error(user_instance, exception, tb):
            formatted_tb = "".join(traceback.format_tb(tb))
            self.log_exception("local", str(exception), formatted_tb)

        self.environment.events.user_error.add_listener(on_user_error)

    def _start(self, user_count: int, spawn_rate: float, wait: bool = False, user_classes: list | None = None) -> None:
        """
        Start running a load test

        :param user_count: Total number of users to start
        :param spawn_rate: Number of users to spawn per second
        :param wait: If True calls to this method will block until all users are spawned.
                     If False (the default), a greenlet that spawns the users will be
                     started and the call to this method will return immediately.
        :param user_classes: The user classes to be dispatched, None indicates to use the classes the dispatcher was
                             invoked with.
        """
        self.target_user_count = user_count

        if self.state != STATE_RUNNING and self.state != STATE_SPAWNING:
            self.stats.clear_all()
            self.exceptions = {}
            self.cpu_warning_emitted = False
            self.worker_cpu_warning_emitted = False
            self.environment._filter_tasks_by_tags()
            self.environment.events.test_start.fire(environment=self.environment)

        if wait and user_count - self.user_count > spawn_rate:
            raise ValueError("wait is True but the amount of users to add is greater than the spawn rate")

        for user_class in self.user_classes:
            if self.environment.host:
                user_class.host = self.environment.host

        if self.state != STATE_INIT and self.state != STATE_STOPPED:
            self.update_state(STATE_SPAWNING)

        if self._users_dispatcher is None:
            self._users_dispatcher = self.environment.dispatcher_class(
                worker_nodes=[self._local_worker_node], user_classes=self.user_classes
            )

        logger.info("Ramping to %d users at a rate of %.2f per second" % (user_count, spawn_rate))

        self._users_dispatcher.new_dispatch(user_count, spawn_rate, user_classes)

        try:
            for dispatched_users in self._users_dispatcher:
                user_classes_spawn_count: dict[str, int] = {}
                user_classes_stop_count: dict[str, int] = {}
                user_classes_count = dispatched_users[self._local_worker_node.id]
                logger.debug(f"Ramping to {_format_user_classes_count_for_log(user_classes_count)}")
                for user_class_name, user_class_count in user_classes_count.items():
                    if self.user_classes_count[user_class_name] > user_class_count:
                        user_classes_stop_count[user_class_name] = (
                            self.user_classes_count[user_class_name] - user_class_count
                        )
                    elif self.user_classes_count[user_class_name] < user_class_count:
                        user_classes_spawn_count[user_class_name] = (
                            user_class_count - self.user_classes_count[user_class_name]
                        )

                if wait:
                    # spawn_users will block, so we need to call stop_users first
                    self.stop_users(user_classes_stop_count)
                    self.spawn_users(user_classes_spawn_count, wait)
                else:
                    # call spawn_users before stopping the users since stop_users
                    # can be blocking because of the stop_timeout
                    self.spawn_users(user_classes_spawn_count, wait)
                    self.stop_users(user_classes_stop_count)

                self._local_worker_node.user_classes_count = next(iter(dispatched_users.values()))

        except KeyboardInterrupt:
            # TODO: Find a cleaner way to handle that
            # We need to catch keyboard interrupt. Otherwise, if KeyboardInterrupt is received while in
            # a gevent.sleep inside the dispatch_users function, locust won't gracefully shutdown.
            self.quit()

        logger.info(f"All users spawned: {_format_user_classes_count_for_log(self.user_classes_count)}")

        self.target_user_classes_count = self.user_classes_count

        self.environment.events.spawning_complete.fire(user_count=sum(self.target_user_classes_count.values()))

    def start(
        self, user_count: int, spawn_rate: float, wait: bool = False, user_classes: list[type[User]] | None = None
    ) -> None:
        if spawn_rate > 100:
            logger.warning(
                "Your selected spawn rate is very high (>100), and this is known to sometimes cause issues. Do you really need to ramp up that fast?"
            )

        if self.spawning_greenlet:
            # kill existing spawning_greenlet before we start a new one
            self.spawning_greenlet.kill(block=True)
        self.spawning_greenlet = self.greenlet.spawn(
            lambda: self._start(user_count, spawn_rate, wait=wait, user_classes=user_classes)
        )
        self.spawning_greenlet.link_exception(locust_exception_handler(self.environment))

    def stop(self) -> None:
        if self.state == STATE_STOPPED:
            return
        super().stop()

    def send_message(self, msg_type: str, data: Any = None, client_id: str | None = None) -> None:
        """
        Emulates internodal messaging by calling registered listeners

        :param msg_type: The type of the message to emulate sending
        :param data: Optional data to include
        """
        logger.debug(f"Running locally: sending {msg_type} message to self")
        if msg_type in self.custom_messages:
            listener, concurrent = self.custom_messages[msg_type]
            msg = Message(msg_type, data, "local")
            listener(environment=self.environment, msg=msg)
        else:
            logger.warning(f"Unknown message type received: {msg_type}")


class DistributedRunner(Runner):
    def __init__(self, environment) -> None:
        super().__init__(environment)
        setup_distributed_stats_event_listeners(self.environment.events, self.stats)


class WorkerNode:
    def __init__(self, id: str, state=STATE_INIT, heartbeat_liveness=HEARTBEAT_LIVENESS) -> None:
        self.id: str = id
        self.state = state
        self.heartbeat = heartbeat_liveness
        self.cpu_usage: int = 0
        self.cpu_warning_emitted = False
        self.memory_usage: int = 0
        # The reported users running on the worker
        self.user_classes_count: dict[str, int] = {}

    @property
    def user_count(self) -> int:
        return sum(self.user_classes_count.values())


class WorkerNodes(MutableMapping):
    def __init__(self) -> None:
        self._worker_nodes: dict[str, WorkerNode] = {}

    def get_by_state(self, state) -> list[WorkerNode]:
        return [c for c in self.values() if c.state == state]

    @property
    def all(self) -> ValuesView[WorkerNode]:
        return self.values()

    @property
    def ready(self) -> list[WorkerNode]:
        return self.get_by_state(STATE_INIT)

    @property
    def spawning(self) -> list[WorkerNode]:
        return self.get_by_state(STATE_SPAWNING)

    @property
    def running(self) -> list[WorkerNode]:
        return self.get_by_state(STATE_RUNNING)

    @property
    def missing(self) -> list[WorkerNode]:
        return self.get_by_state(STATE_MISSING)

    def __setitem__(self, k: str, v: WorkerNode) -> None:
        self._worker_nodes[k] = v

    def __delitem__(self, k: str) -> None:
        del self._worker_nodes[k]

    def __getitem__(self, k: str) -> WorkerNode:
        return self._worker_nodes[k]

    def __len__(self) -> int:
        return len(self._worker_nodes)

    def __iter__(self) -> Iterator[str]:
        return iter(list(self._worker_nodes.keys()))


class MasterRunner(DistributedRunner):
    """
    Runner used to run distributed load tests across multiple processes and/or machines.

    MasterRunner doesn't spawn any user greenlets itself. Instead it expects
    :class:`WorkerRunners <WorkerRunner>` to connect to it, which it will then direct
    to start and stop user greenlets. Stats sent back from the
    :class:`WorkerRunners <WorkerRunner>` will aggregated.
    """

    def __init__(self, environment, master_bind_host, master_bind_port) -> None:
        """
        :param environment: Environment instance
        :param master_bind_host: Host/interface to use for incoming worker connections
        :param master_bind_port: Port to use for incoming worker connections
        """
        super().__init__(environment)
        self.worker_cpu_warning_emitted = False
        self.master_bind_host = master_bind_host
        self.master_bind_port = master_bind_port
        self.spawn_rate: float = 0.0
        self.spawning_completed = False
        self.worker_indexes: dict[str, int] = {}
        self.worker_index_max = 0

        self.clients = WorkerNodes()
        try:
            self.server = rpc.Server(master_bind_host, master_bind_port)
        except RPCError as e:
            if e.args[0] == "Socket bind failure: Address already in use":
                port_string = (
                    master_bind_host + ":" + str(master_bind_port) if master_bind_host != "*" else str(master_bind_port)
                )
                logger.error(
                    f"The Locust master port ({port_string}) was busy. Close any applications using that port - perhaps an old instance of Locust master is still running? ({e.args[0]})"
                )
                sys.exit(1)
            else:
                raise

        self._users_dispatcher: UsersDispatcher | None = None

        self.greenlet.spawn(self.heartbeat_worker).link_exception(locust_exception_handler(self.environment))
        self.greenlet.spawn(self.client_listener).link_exception(locust_exception_handler(self.environment))

        # listener that gathers info on how many users the worker has spawned
        def on_worker_report(client_id: str, data: dict[str, Any]) -> None:
            if client_id not in self.clients:
                logger.info("Discarded report from unrecognized worker %s", client_id)
                return
            self.clients[client_id].user_classes_count = data["user_classes_count"]

        self.environment.events.worker_report.add_listener(on_worker_report)

        # register listener that sends quit message to worker nodes
        def on_quitting(environment: Environment, **kw):
            self.quit()

        self.environment.events.quitting.add_listener(on_quitting)

    def rebalancing_enabled(self) -> bool:
        return self.environment.parsed_options is not None and cast(
            bool, self.environment.parsed_options.enable_rebalancing
        )

    def get_worker_index(self, client_id):
        """
        Get the worker index for the specified client ID;
        this is a deterministic 0-based ordinal number and guaranteed to not change
        while Master is alive.
        """
        if client_id in self.worker_indexes:
            return self.worker_indexes[client_id]
        index = self.worker_index_max
        self.worker_indexes[client_id] = index
        self.worker_index_max += 1
        return index

    @property
    def user_count(self) -> int:
        return sum([c.user_count for c in self.clients.values()])

    def cpu_log_warning(self) -> bool:
        warning_emitted = Runner.cpu_log_warning(self)
        if self.worker_cpu_warning_emitted:
            logger.warning("CPU usage threshold was exceeded on workers during the test!")
            warning_emitted = True
        return warning_emitted

    def start(
        self, user_count: int, spawn_rate: float, wait=False, user_classes: list[type[User]] | None = None
    ) -> None:
        self.spawning_completed = False

        self.target_user_count = user_count

        active_workers = self.clients.ready + self.clients.running + self.clients.spawning
        num_workers = len(active_workers)
        if not num_workers:
            logger.warning("You can't start a distributed test before at least one worker processes has connected")
            return

        for user_class in self.user_classes:
            if self.environment.host:
                user_class.host = self.environment.host

        self.spawn_rate = spawn_rate

        if self._users_dispatcher is None:
            self._users_dispatcher = self.environment.dispatcher_class(
                worker_nodes=active_workers, user_classes=self.user_classes
            )

        logger.info(
            "Sending spawn jobs of %d users at %.2f spawn rate to %d ready workers"
            % (user_count, spawn_rate, num_workers)
        )

        worker_spawn_rate = float(spawn_rate) / (num_workers or 1)
        if worker_spawn_rate > 100:
            logger.warning(
                "Your selected spawn rate is very high (>100/worker), and this is known to sometimes cause issues. Do you really need to ramp up that fast?"
            )

        if self.state != STATE_RUNNING and self.state != STATE_SPAWNING:
            self.stats.clear_all()
            self.exceptions = {}
            self.environment._filter_tasks_by_tags()
            self.environment.events.test_start.fire(environment=self.environment)
            if self.environment.shape_class:
                self.environment.shape_class.reset_time()

        self.update_state(STATE_SPAWNING)

        self._users_dispatcher.new_dispatch(
            target_user_count=user_count, spawn_rate=spawn_rate, user_classes=user_classes
        )

        try:
            for dispatched_users in self._users_dispatcher:
                dispatch_greenlets = Group()
                for worker_node_id, worker_user_classes_count in dispatched_users.items():
                    data = {
                        "timestamp": time.time(),
                        "user_classes_count": worker_user_classes_count,
                        "host": self.environment.host,
                        "stop_timeout": self.environment.stop_timeout,
                        "parsed_options": vars(self.environment.parsed_options)
                        if self.environment.parsed_options
                        else {},
                    }
                    dispatch_greenlets.add(
                        gevent.spawn_later(
                            0,
                            self.server.send_to_client,
                            Message("spawn", data, worker_node_id),
                        )
                    )
                dispatched_user_count = sum(map(sum, map(methodcaller("values"), dispatched_users.values())))
                logger.debug(
                    "Sending spawn messages for %g total users to %i worker(s)",
                    dispatched_user_count,
                    len(dispatch_greenlets),
                )
                dispatch_greenlets.join()

                logger.debug(
                    f"Currently spawned users: {_format_user_classes_count_for_log(self.reported_user_classes_count)}"
                )

            self.target_user_classes_count = _aggregate_dispatched_users(dispatched_users)

        except KeyboardInterrupt:
            # TODO: Find a cleaner way to handle that
            # We need to catch keyboard interrupt. Otherwise, if KeyboardInterrupt is received while in
            # a gevent.sleep inside the dispatch_users function, locust won't gracefully shutdown.
            self.quit()

        # Wait a little for workers to report their users to the master
        # so that we can give an accurate log message below and fire the `spawning_complete` event
        # when the user count is really at the desired value.
        timeout = gevent.Timeout(self._wait_for_workers_report_after_ramp_up())
        timeout.start()
        msg_prefix = "All users spawned"
        try:
            while self.user_count != self.target_user_count:
                gevent.sleep(0.01)
        except gevent.Timeout:
            msg_prefix = (
                "Spawning is complete and report waittime is expired, but not all reports received from workers"
            )
        finally:
            timeout.cancel()

        user_count = sum(self.target_user_classes_count.values())
        self.environment.events.spawning_complete.fire(user_count=user_count)
        # notify workers so they can fire their own event
        self.send_message("spawning_complete", data={"user_count": user_count})
        self.spawning_completed = True

        logger.info(f"{msg_prefix}: {_format_user_classes_count_for_log(self.reported_user_classes_count)}")

    @functools.lru_cache
    def _wait_for_workers_report_after_ramp_up(self) -> float:
        """
        The amount of time to wait after a ramp-up in order for all the workers to report their state
        to the master. If not supplied by the user, it is 1000ms by default. If the supplied value is a number,
        it is taken as-is. If the supplied value is a pattern like "some_number * WORKER_REPORT_INTERVAL",
        the value will be "some_number * WORKER_REPORT_INTERVAL". The most sensible value would be something
        like "1.25 * WORKER_REPORT_INTERVAL". However, some users might find it too high, so it is left
        to a relatively small value of 1000ms by default.
        """
        locust_wait_for_workers_report_after_ramp_up = os.getenv("LOCUST_WAIT_FOR_WORKERS_REPORT_AFTER_RAMP_UP")
        if locust_wait_for_workers_report_after_ramp_up is None:
            return 1.0

        match = re.search(
            r"^(?P<coeff>(\d+)|(\d+\.\d+))[ ]*\*[ ]*WORKER_REPORT_INTERVAL$",
            locust_wait_for_workers_report_after_ramp_up,
        )
        if match is None:
            assert float(locust_wait_for_workers_report_after_ramp_up) >= 0
            return float(locust_wait_for_workers_report_after_ramp_up)
        else:
            return float(match.group("coeff")) * WORKER_REPORT_INTERVAL

    def stop(self, send_stop_to_client: bool = True) -> None:
        if self.state not in [STATE_INIT, STATE_STOPPED, STATE_STOPPING]:
            logger.debug("Stopping...")
            self.environment.events.test_stopping.fire(environment=self.environment)
            self.final_user_classes_count = {**self.reported_user_classes_count}
            self.update_state(STATE_STOPPING)

            if (
                self.environment.shape_class is not None
                and self.shape_greenlet is not None
                and self.shape_greenlet is not greenlet.getcurrent()
            ):
                self.shape_greenlet.kill(block=True)
                self.shape_greenlet = None
                self.shape_last_tick = None

            self._users_dispatcher = None

            if send_stop_to_client:
                for client in self.clients.all:
                    logger.debug(f"Sending stop message to worker {client.id}")
                    self.server.send_to_client(Message("stop", None, client.id))

                # Give an additional 60s for all workers to stop
                timeout = gevent.Timeout(self.environment.stop_timeout + 60)
                timeout.start()
                try:
                    while self.user_count != 0:
                        gevent.sleep(1)
                except gevent.Timeout:
                    logger.error("Timeout waiting for all workers to stop")
                finally:
                    timeout.cancel()
            self.environment.events.test_stop.fire(environment=self.environment)

    def quit(self) -> None:
        self.stop(send_stop_to_client=False)
        logger.debug("Quitting...")
        for client in self.clients.all:
            logger.debug(f"Sending quit message to worker {client.id} (index {self.get_worker_index(client.id)})")
            self.server.send_to_client(Message("quit", None, client.id))
        gevent.sleep(0.5)  # wait for final stats report from all workers
        self.greenlet.kill(block=True)

    def check_stopped(self) -> None:
        if (
            self.state == STATE_STOPPING
            and all(x.state == STATE_INIT for x in self.clients.all)
            or all(x.state not in (STATE_RUNNING, STATE_SPAWNING, STATE_INIT) for x in self.clients.all)
        ):
            self.update_state(STATE_STOPPED)

    def heartbeat_worker(self) -> NoReturn:
        while True:
            gevent.sleep(HEARTBEAT_INTERVAL)
            if self.connection_broken:
                self.reset_connection()
                continue

            missing_clients_to_be_removed = []
            for client in self.clients.all:
                # if clients goes missing for more than HEARTBEAT_DEAD_INTERNAL then add them to be removed list
                if client.state == STATE_MISSING and client.heartbeat <= HEARTBEAT_DEAD_INTERNAL:
                    missing_clients_to_be_removed.append(client.id)

                if client.heartbeat < 0 and client.state != STATE_MISSING:
                    logger.info(f"Worker {str(client.id)} failed to send heartbeat, setting state to missing.")
                    client.state = STATE_MISSING
                    client.user_classes_count = {}
                    if self._users_dispatcher is not None:
                        self._users_dispatcher.remove_worker(client)
                        if self.rebalancing_enabled() and self.state == STATE_RUNNING and self.spawning_completed:
                            self.start(self.target_user_count, self.spawn_rate)
                    if self.worker_count <= 0:
                        logger.info("The last worker went missing, stopping test.")
                        self.stop()
                        self.check_stopped()
                else:
                    client.heartbeat -= 1

            # if there are any missing clients to be removed then remove them and trigger rebalance.
            if len(missing_clients_to_be_removed) > 0:
                for to_remove_client_id in missing_clients_to_be_removed:
                    if self.clients.get(to_remove_client_id) is not None:
                        del self.clients[to_remove_client_id]
                if self.state == STATE_RUNNING or self.state == STATE_SPAWNING:
                    # _users_dispatcher is set to none so that during redistribution the dead clients are not picked, alternative is to call self.stop() before start
                    self._users_dispatcher = None
                    # trigger redistribution after missing cclient removal
                    self.start(user_count=self.target_user_count, spawn_rate=self.spawn_rate)

    def reset_connection(self) -> None:
        logger.info("Resetting RPC server and all worker connections.")
        try:
            self.server.close(linger=0)
            self.server = rpc.Server(self.master_bind_host, self.master_bind_port)
            self.connection_broken = False
        except RPCError as e:
            logger.error(f"Temporary failure when resetting connection: {e}, will retry later.")

    def client_listener(self) -> NoReturn:
        while True:
            try:
                client_id, msg = self.server.recv_from_client()
            except RPCReceiveError as e:
                client_id = e.addr

                if client_id and client_id in self.clients:
                    logger.error(f"RPCError when receiving from client: {e}. Will reset client {client_id}.")
                    try:
                        self.server.send_to_client(Message("reconnect", None, client_id))
                    except Exception as error:
                        logger.error(f"Error sending reconnect message to worker: {error}. Will reset RPC server.")
                        self.connection_broken = True
                        gevent.sleep(FALLBACK_INTERVAL)
                        continue
                else:
                    message = f"{e}" if not client_id else f"{e} from {client_id}"
                    logger.error(f"Unrecognized message detected: {message}")
                    continue
            except RPCSendError as e:
                logger.error(f"Error sending reconnect message to worker: {e}. Will reset RPC server.")
                self.connection_broken = True
                gevent.sleep(FALLBACK_INTERVAL)
                continue
            except RPCError as e:
                if self.clients.ready or self.clients.spawning or self.clients.running:
                    logger.error(f"RPCError: {e}. Will reset RPC server.")
                else:
                    logger.debug(
                        f"RPCError when receiving from worker: {e} (but no workers were expected to be connected anyway)"
                    )
                self.connection_broken = True
                gevent.sleep(FALLBACK_INTERVAL)
                continue
            except KeyboardInterrupt:
                logging.debug(
                    "Got KeyboardInterrupt in client_listener. Other greenlets should catch this and shut down."
                )
                continue
            self.handle_message(client_id, msg)

    def handle_message(self, client_id: str, msg: Message) -> None:
        match msg.type:
            case "client_ready":
                if not msg.data:
                    logger.error(f"An old (pre 2.0) worker tried to connect ({client_id}). That's not going to work.")
                    return
                elif msg.data != __version__ and msg.data != -1:
                    if msg.data[0:4] == __version__[0:4]:
                        logger.debug(
                            f"A worker ({client_id}) running a different patch version ({repr(msg.data)}) connected, master version is {repr(__version__)}"
                        )
                    else:
                        logger.warning(
                            f"A worker ({client_id}) running a different version ({msg.data}) connected, master version is {__version__}"
                        )
                self.send_message("ack", client_id=client_id, data={"index": self.get_worker_index(client_id)})
                self.environment.events.worker_connect.fire(client_id=msg.node_id)
                client_already_connected = client_id in self.clients
                self.clients[client_id] = WorkerNode(client_id, heartbeat_liveness=HEARTBEAT_LIVENESS)
                if self._users_dispatcher is not None:
                    self._users_dispatcher.add_worker(worker_node=self.clients[client_id])
                    if not self._users_dispatcher.dispatch_in_progress and self.state == STATE_RUNNING:
                        # TODO: Test this situation
                        self.start(self.target_user_count, self.spawn_rate)
                if client_already_connected:
                    logger.debug(
                        f"{client_id} (index {self.get_worker_index(client_id)}) reported as ready (duplicate message). {len(self.clients.ready + self.clients.running + self.clients.spawning)} workers connected."
                    )
                else:
                    logger.info(
                        f"{client_id} (index {self.get_worker_index(client_id)}) reported as ready. {len(self.clients.ready + self.clients.running + self.clients.spawning)} workers connected."
                    )
                if self.rebalancing_enabled() and self.state == STATE_RUNNING and self.spawning_completed:
                    self.start(self.target_user_count, self.spawn_rate)
                # emit a warning if the worker's clock seem to be out of sync with our clock
                # if abs(time() - msg.data["time"]) > 5.0:
                #    warnings.warn("The worker node's clock seem to be out of sync. For the statistics to be correct the different locust servers need to have synchronized clocks.")
            case "locustfile":
                if not msg.data["version"]:
                    logger.error("A very old worker version requested locustfile. This probably won't work.")
                elif msg.data["version"][0:4] == __version__[0:4]:
                    logger.debug(
                        f"A worker ({msg.node_id}) running a different patch version ({msg.data['version']}) connected, master version is {__version__}"
                    )

                logging.debug("Worker requested locust file")
                assert self.environment.parsed_locustfiles
                locustfile_options = self.environment.parsed_locustfiles
                locustfile_list = [f.strip() for f in locustfile_options if not os.path.isdir(f)]

                for locustfile_option in locustfile_options:
                    if os.path.isdir(locustfile_option):
                        locustfile_list.extend(get_abspaths_in(locustfile_option, extension=".py"))

                try:
                    locustfiles: list[str | dict[str, str]] = []

                    for filename in locustfile_list:
                        if is_url(filename):
                            locustfiles.append(filename)
                        else:
                            with open(filename) as f:
                                filename = os.path.basename(filename)
                                file_contents = f.read()

                            locustfiles.append({"filename": filename, "contents": file_contents})
                except Exception as e:
                    error_message = "locustfile must be a full path to a single locustfile, a comma-separated list of .py files, or a URL for file distribution to work"
                    logger.error(f"{error_message} {e}")
                    self.send_message(
                        "locustfile",
                        client_id=client_id,
                        data={"error": f"{error_message} (was '{filename}')"},
                    )
                else:
                    self.send_message(
                        "locustfile",
                        client_id=client_id,
                        data={"locustfiles": locustfiles},
                    )
                return
            case "client_stopped":
                if msg.node_id not in self.clients:
                    logger.warning(f"Received {msg.type} message from an unknown worker: {msg.node_id}.")
                    return
                client = self.clients[msg.node_id]
                del self.clients[msg.node_id]
                if self._users_dispatcher is not None:
                    self._users_dispatcher.remove_worker(client)
                    if not self._users_dispatcher.dispatch_in_progress and self.state == STATE_RUNNING:
                        # TODO: Test this situation
                        self.start(self.target_user_count, self.spawn_rate)
                logger.info(f"{msg.node_id} (index {self.get_worker_index(client_id)}) reported that it has stopped")
            case "heartbeat":
                if msg.node_id in self.clients:
                    c = self.clients[msg.node_id]
                    c.heartbeat = HEARTBEAT_LIVENESS
                    client_state = msg.data["state"]
                    if c.state == STATE_MISSING:
                        logger.info(f"Worker {str(c.id)} self-healed with heartbeat, setting state to {client_state}.")
                        if self._users_dispatcher is not None:
                            self._users_dispatcher.add_worker(worker_node=c)
                            if not self._users_dispatcher.dispatch_in_progress and self.state == STATE_RUNNING:
                                # TODO: Test this situation
                                self.start(self.target_user_count, self.spawn_rate)
                    c.state = client_state
                    c.cpu_usage = msg.data["current_cpu_usage"]
                    if not c.cpu_warning_emitted and c.cpu_usage > 90:
                        self.worker_cpu_warning_emitted = True  # used to fail the test in the end
                        c.cpu_warning_emitted = True  # used to suppress logging for this node
                        logger.warning(
                            f"Worker {msg.node_id} (index {self.get_worker_index(msg.node_id)}) exceeded cpu threshold (will only log this once per worker)"
                        )
                    if "current_memory_usage" in msg.data:
                        c.memory_usage = msg.data["current_memory_usage"]
                    self.environment.events.heartbeat_sent.fire(client_id=msg.node_id, timestamp=time.time())
                    self.server.send_to_client(Message("heartbeat", None, msg.node_id))
                else:
                    logging.debug(f"Got heartbeat message from unknown worker {msg.node_id}")
            case "stats":
                self.environment.events.worker_report.fire(client_id=msg.node_id, data=msg.data)
            case "spawning":
                try:
                    self.clients[msg.node_id].state = STATE_SPAWNING
                except KeyError:
                    logger.warning(f"Got spawning message from unknown worker {msg.node_id}. Asking worker to quit.")
                    self.server.send_to_client(Message("quit", None, msg.node_id))
            case "spawning_complete":
                # a worker finished spawning (this happens multiple times during rampup)
                self.clients[msg.node_id].state = STATE_RUNNING
                self.clients[msg.node_id].user_classes_count = msg.data["user_classes_count"]
            case "logs":
                self.environment.update_worker_logs(msg.data)
            case "quit":
                if msg.node_id in self.clients:
                    client = self.clients[msg.node_id]
                    del self.clients[msg.node_id]
                    if self._users_dispatcher is not None:
                        self._users_dispatcher.remove_worker(client)
                        if not self._users_dispatcher.dispatch_in_progress and self.state == STATE_RUNNING:
                            # TODO: Test this situation
                            self.start(self.target_user_count, self.spawn_rate)
                    logger.info(
                        f"Worker {msg.node_id!r} (index {self.get_worker_index(msg.node_id)}) quit. {len(self.clients.ready)} workers r

        """
        Sends a message to attached worker node(s)

        :param msg_type: The type of the message to send
        :param data: Optional data to send
        :param client_id: Optional id of the target worker node.
                            If None, will send to all attached workers
        """
        if client_id:
            logger.debug(f"Sending {msg_type} message to worker {client_id}")
            self.server.send_to_client(Message(msg_type, data, client_id))
        else:
            for client in self.clients.all:
                logger.debug(f"Sending {msg_type} message to worker {client.id}")
                self.server.send_to_client(Message(msg_type, data, client.id))


class WorkerRunner(DistributedRunner):
    """
    Runner used to run distributed load tests across multiple processes and/or machines.

    WorkerRunner connects to a :class:`MasterRunner` from which it'll receive
    instructions to start and stop user greenlets. The WorkerRunner will periodically
    take the stats generated by the running users and send back to the :class:`MasterRunner`.
    """

    # the worker index is set on ACK, if master provided it (masters <= 2.10.2 do not provide it)
    worker_index = -1

    def __init__(self, environment: Environment, master_host: str, master_port: int) -> None:
        """
        :param environment: Environment instance
        :param master_host: Host/IP to use for connection to the master
        :param master_port: Port to use for connecting to the master
        """
        super().__init__(environment)
        self.retry = 0
        self.connected = False
        self.last_heartbeat_timestamp: float | None = None
        self.connection_event = Event()
        self.worker_state = STATE_INIT
        self.client_id = socket.gethostname() + "_" + uuid4().hex
        self.master_host = master_host
        self.master_port = master_port
        self.web_base_path = environment.parsed_options.web_base_path if environment.parsed_options else ""
        self.logs: list[str] = []
        self.worker_cpu_warning_emitted = False
        self._users_dispatcher: UsersDispatcher | None = None
        self.client = rpc.Client(master_host, master_port, self.client_id)
        self.greenlet.spawn(self.worker).link_exception(locust_exception_handler(self.environment))
        self.connect_to_master()
        self.greenlet.spawn(self.heartbeat).link_exception(locust_exception_handler(self.environment))
        self.greenlet.spawn(self.heartbeat_timeout_checker).link_exception(locust_exception_handler(self.environment))
        self.greenlet.spawn(self.stats_reporter).link_exception(locust_exception_handler(self.environment))
        self.greenlet.spawn(self.logs_reporter).link_exception(locust_exception_handler(self.environment))

        # register listener that adds the current number of spawned users to the report that is sent to the master node
        def on_report_to_master(client_id: str, data: dict[str, Any]):
            data["user_classes_count"] = self.user_classes_count
            data["user_count"] = self.user_count

        self.environment.events.report_to_master.add_listener(on_report_to_master)

        # register listener that sends quit message to master
        def on_quitting(environment: Environment, **kw) -> None:
            self.client.send(Message("quit", None, self.client_id))

        self.environment.events.quitting.add_listener(on_quitting)

        # register listener that's sends user exceptions to master
        def on_user_error(user_instance: User, exception: Exception, tb: TracebackType) -> None:
            formatted_tb = "".join(traceback.format_tb(tb))
            self.client.send(Message("exception", {"msg": str(exception), "traceback": formatted_tb}, self.client_id))

        self.environment.events.user_error.add_listener(on_user_error)

    def spawning_complete(self, user_count):
        assert user_count == sum(self.user_classes_count.values())
        self.client.send(
            Message(
                "spawning_complete",
                {"user_classes_count": self.user_classes_count, "user_count": self.user_count},
                self.client_id,
            )
        )
        self.worker_state = STATE_RUNNING

    def start(
        self, user_count: int, spawn_rate: float, wait: bool = False, user_classes: list[type[User]] | None = None
    ) -> None:
        raise NotImplementedError("use start_worker")

    def start_worker(self, user_classes_count: dict[str, int], **kwargs) -> None:
        """
        Start running a load test as a worker

        :param user_classes_count: Users to run
        """
        self.target_user_classes_count = user_classes_count
        self.target_user_count = sum(user_classes_count.values())

        for user_class in self.user_classes:
            if self.environment.host:
                user_class.host = self.environment.host

        user_classes_spawn_count: dict[str, int] = {}
        user_classes_stop_count: dict[str, int] = {}

        for user_class_name, user_class_count in user_classes_count.items():
            if self.user_classes_count[user_class_name] > user_class_count:
                user_classes_stop_count[user_class_name] = self.user_classes_count[user_class_name] - user_class_count
            elif self.user_classes_count[user_class_name] < user_class_count:
                user_classes_spawn_count[user_class_name] = user_class_count - self.user_classes_count[user_class_name]

        # call spawn_users before stopping the users since stop_users
        # can be blocking because of the stop_timeout
        self.spawn_users(user_classes_spawn_count)
        self.stop_users(user_classes_stop_count)
        self.spawning_complete(sum(self.user_classes_count.values()))
        self.update_state(STATE_RUNNING)
        self.worker_state = STATE_RUNNING

    def heartbeat(self) -> NoReturn:
        while True:
            try:
                self.client.send(
                    Message(
                        "heartbeat",
                        {
                            "state": self.worker_state,
                            "current_cpu_usage": self.current_cpu_usage,
                            "current_memory_usage": self.current_memory_usage,
                        },
                        self.client_id,
                    )
                )
            except RPCError as e:
                logger.error(f"RPCError found when sending heartbeat: {e}")
                self.reset_connection()
            gevent.sleep(HEARTBEAT_INTERVAL)

    def heartbeat_timeout_checker(self) -> NoReturn:
        while True:
            gevent.sleep(1)
            if self.last_heartbeat_timestamp and self.last_heartbeat_timestamp < time.time() - MASTER_HEARTBEAT_TIMEOUT:
                logger.error(f"Didn't get heartbeat from master in over {MASTER_HEARTBEAT_TIMEOUT}s")
                self.quit()

    def reset_connection(self) -> None:
        logger.info("Reset connection to master")
        try:
            self.client.close()
            self.client = rpc.Client(self.master_host, self.master_port, self.client_id)
        except RPCError as e:
            logger.error(f"Temporary failure when resetting connection: {e}, will retry later.")

    def worker(self) -> NoReturn:
        self.last_received_spawn_timestamp = 0
        while True:
            try:
                msg = self.client.recv()
            except RPCError as e:
                logger.error(f"RPCError found when receiving from master: {e}")
            else:
                self.handle_message(msg)

    def handle_message(self, msg: Message) -> None:
        match msg.type:
            case "ack":
                # backward-compatible support of masters that do not send a worker index
                if msg.data is not None and "index" in msg.data:
                    self.worker_index = msg.data["index"]
                self.connection_event.set()
            case "spawn":
                self.client.send(Message("spawning", None, self.client_id))
                job = msg.data
                if job["timestamp"] <= self.last_received_spawn_timestamp:
                    logger.info(
                        "Discard spawn message with older or equal timestamp than timestamp of previous spawn message"
                    )
                    return
                self.environment.host = job["host"]
                self.environment.stop_timeout = job["stop_timeout"] or 0.0

                # receive custom arguments
                if self.environment.parsed_options is None:
                    default_parser = argument_parser.get_empty_argument_parser()
                    argument_parser.setup_parser_arguments(default_parser)
                    self.environment.parsed_options = default_parser.parse(args=[])
                custom_args_from_master = {
                    k: v
                    for k, v in job["parsed_options"].items()
                    if k not in argument_parser.default_args_dict()
                    # these settings are sometimes needed on workers
                    or k in ["expect_workers", "tags", "exclude_tags"]
                }
                vars(self.environment.parsed_options).update(custom_args_from_master)

                if self.worker_state != STATE_RUNNING and self.worker_state != STATE_SPAWNING:
                    self.stats.clear_all()


                    self.exceptions = {}
                    self.cpu_warning_emitted = False
                    self.worker_cpu_warning_emitted = False
                    self.environment._filter_tasks_by_tags()
                    self.environment.events.test_start.fire(environment=self.environment)

                self.worker_state = STATE_SPAWNING

                if self.spawning_greenlet:
                    # kill existing spawning greenlet before we launch new one
                    self.spawning_greenlet.kill(block=True)
                self.spawning_greenlet = self.greenlet.spawn(lambda: self.start_worker(job["user_classes_count"]))
                self.spawning_greenlet.link_exception(locust_exception_handler(self.environment))
                self.last_received_spawn_timestamp = job["timestamp"]
            case "stop":
                self.stop()
                self.client.send(Message("client_stopped", None, self.client_id))
                # +additional_wait is just a small buffer to account for the random network latencies and/or other
                # random delays inherent to distributed systems.
                additional_wait = int(os.getenv("LOCUST_WORKER_ADDITIONAL_WAIT_BEFORE_READY_AFTER_STOP", 0))
                gevent.sleep(self.environment.stop_timeout + additional_wait)
                self.client.send(Message("client_ready", __version__, self.client_id))
                self.worker_state = STATE_INIT
            case "quit":
                logger.info("Got quit message from master, shutting down...")
                self.stop()
                self._send_stats()  # send a final report, in case there were any samples not yet reported
                self.greenlet.kill(block=True)
            case "reconnect":
                logger.warning("Received reconnect message from master. Resetting RPC connection.")
                self.reset_connection()
            case "heartbeat":
                self.last_heartbeat_timestamp = time.time()
                self.environment.events.heartbeat_received.fire(
                    client_id=msg.node_id, timestamp=self.last_heartbeat_timestamp
                )
            case "update_user_class":
                self.environment.update_user_class(msg.data)
            case "spawning_complete":
                # master says we have finished spawning (happens only once during a normal rampup)
                self.environment.events.spawning_complete.fire(user_count=msg.data["user_count"])
            case _ if lc := self.custom_messages.get(msg.type):
                listener, concurrent = lc
                logger.debug(f"Received {msg.type} message from master")
                if not concurrent:
                    listener(environment=self.environment, msg=msg)
                else:
                    gevent.spawn(listener, self.environment, msg)
            case _:
                logger.warning(f"Unknown message type received: {msg.type}")

    def stats_reporter(self) -> NoReturn:
        while True:
            try:
                self._send_stats()
            except RPCError as e:
                logger.error(f"Temporary connection lost to master server: {e}, will retry later.")
            gevent.sleep(WORKER_REPORT_INTERVAL)

    def logs_reporter(self) -> None:
        if WORKER_LOG_REPORT_INTERVAL < 0:
            return

        while True:
            current_logs = get_logs()

            if (len(current_logs) - len(self.logs)) > 70:
                logger.warning(
                    "The worker attempted to send more than 70 log lines in one interval. Further log sending was disabled for this worker."
                )
                self._send_logs(get_logs())
                break
            if len(current_logs) > len(self.logs):
                self._send_logs(current_logs)

            self.logs = current_logs
            gevent.sleep(WORKER_LOG_REPORT_INTERVAL)

    def send_message(self, msg_type: str, data: dict[str, Any] | None = None, client_id: str | None = None) -> None:
        """
        Sends a message to master node

        :param msg_type: The type of the message to send
        :param data: Optional data to send
        :param client_id: (unused)
        """
        logger.debug(f"Sending {msg_type} message to master")
        self.client.send(Message(msg_type, data, self.client_id))

    def _send_stats(self) -> None:
        data: dict[str, Any] = {}
        self.environment.events.report_to_master.fire(client_id=self.client_id, data=data)
        self.client.send(Message("stats", data, self.client_id))

    def _send_logs(self, current_logs) -> None:
        self.send_message("logs", {"worker_id": self.client_id, "logs": current_logs})

    def connect_to_master(self):
        self.retry += 1
        self.client.send(Message("client_ready", __version__, self.client_id))
        try:
            success = self.connection_event.wait(timeout=CONNECT_TIMEOUT)
        except KeyboardInterrupt:
            # dont complain about getting CTRL-C
            sys.exit(1)
        if not success:
            if self.retry < 30 / CONNECT_TIMEOUT:  # lower log level during the first 30 seconds
                logger.debug(
                    f"Failed to connect to master {self.master_host}:{self.master_port}{self.web_base_path}, retry {self.retry}/{CONNECT_RETRY_COUNT}."
                )
            else:
                logger.info(
                    f"Failed to connect to master {self.master_host}:{self.master_port}{self.web_base_path}, retry {self.retry}/{CONNECT_RETRY_COUNT}."
                )
            if self.retry > CONNECT_RETRY_COUNT:
                raise ConnectionError()
            self.connect_to_master()
        self.connected = True


def _format_user_classes_count_for_log(user_classes_count: dict[str, int]) -> str:
    return "{} ({} total users)".format(  # noqa: UP032
        json.dumps(dict(sorted(user_classes_count.items(), key=itemgetter(0)))),
        sum(user_classes_count.values()),
    )


def _aggregate_dispatched_users(d: dict[str, dict[str, int]]) -> dict[str, int]:
    # TODO: Test it
    user_classes = list(next(iter(d.values())).keys())
    return {u: sum(worker_counts[u] for worker_counts in d.values()) for u in user_classes}


parte p3

from __future__ import annotations

from collections.abc import Callable
from operator import methodcaller
from typing import TypeVar

from configargparse import Namespace

from .dispatch import UsersDispatcher
from .event import Events
from .exception import RunnerAlreadyExistsError
from .runners import LocalRunner, MasterRunner, Runner, WorkerRunner
from .shape import LoadTestShape
from .stats import RequestStats, StatsCSV
from .user import User
from .user.task import TaskHolder, TaskSet, filter_tasks_by_tags
from .web import WebUI

RunnerType = TypeVar("RunnerType", bound=Runner)


class Environment:
    def __init__(
        self,
        *,
        user_classes: list[type[User]] | None = None,
        shape_class: LoadTestShape | None = None,
        tags: list[str] | None = None,
        locustfile: str | None = None,
        exclude_tags: list[str] | None = None,
        events: Events | None = None,
        host: str | None = None,
        reset_stats=False,
        stop_timeout: float | None = None,
        catch_exceptions=True,
        parsed_options: Namespace | None = None,
        parsed_locustfiles: list[str] | None = None,
        available_user_classes: dict[str, User] | None = None,
        available_shape_classes: dict[str, LoadTestShape] | None = None,
        available_user_tasks: dict[str, list[TaskSet | Callable]] | None = None,
        dispatcher_class: type[UsersDispatcher] = UsersDispatcher,
        profile: str | None = None,
    ):
        self.runner: Runner | None = None
        """Reference to the :class:`Runner <locust.runners.Runner>` instance"""

        self.web_ui: WebUI | None = None
        """Reference to the WebUI instance"""

        self.process_exit_code: int | None = None
        """
        If set it'll be the exit code of the Locust process
        """

        if events:
            self.events = events
            """
            Event hooks used by Locust internally, as well as to extend Locust's functionality
            See :ref:`events` for available events.
            """
        else:
            self.events = Events()

        self.locustfile = locustfile
        """Filename (not path) of locustfile"""
        self.user_classes: list[type[User]] = user_classes or []
        """User classes that the runner will run"""
        self.shape_class = shape_class
        """A shape class to control the shape of the load test"""
        self.tags = tags
        """If set, only tasks that are tagged by tags in this list will be executed. Leave this as None to use the one from parsed_options"""
        self.exclude_tags = exclude_tags
        """If set, only tasks that aren't tagged by tags in this list will be executed. Leave this as None to use the one from parsed_options"""
        self.stats = RequestStats()
        """Reference to RequestStats instance"""
        self.host = host
        """Base URL of the target system"""
        self.reset_stats = reset_stats
        """Determines if stats should be reset once all simulated users have been spawned"""
        self.profile = profile
        """Profile name for the test run"""
        if stop_timeout is not None:
            self.stop_timeout = stop_timeout
        elif parsed_options:
            self.stop_timeout = float(getattr(parsed_options, "stop_timeout", 0.0))
        else:
            self.stop_timeout = 0.0
        """
        If set, the runner will try to stop the running users gracefully and wait this many seconds
        before killing them hard.
        """
        self.catch_exceptions = catch_exceptions
        """
        If True exceptions that happen within running users will be caught (and reported in UI/console).
        If False, exceptions will be raised.
        """
        self.parsed_options = parsed_options
        """Reference to the parsed command line options (used to pre-populate fields in Web UI). When using Locust as a library, this should either be `None` or an object created by `argument_parser.parse_args()`"""
        self.parsed_locustfiles = parsed_locustfiles
        """A list of all locustfiles for the test"""
        self.available_user_classes = available_user_classes
        """List of the available User Classes to pick from in the UserClass Picker"""
        self.available_shape_classes = available_shape_classes
        """List of the available Shape Classes to pick from in the ShapeClass Picker"""
        self.available_user_tasks = available_user_tasks
        """List of the available Tasks per User Classes to pick from in the Task Picker"""
        self.dispatcher_class = dispatcher_class
        """A user dispatcher class that decides how users are spawned, default :class:`UsersDispatcher <locust.dispatch.UsersDispatcher>`"""
        self.worker_logs: dict[str, list[str]] = {}
        """Captured logs from all connected workers"""

        self._remove_user_classes_with_weight_zero()
        self._validate_user_class_name_uniqueness()
        self._validate_shape_class_instance()

    def _create_runner(
        self,
        runner_class: type[RunnerType],
        *args,
        **kwargs,
    ) -> RunnerType:
        if self.runner is not None:
            raise RunnerAlreadyExistsError(f"Environment.runner already exists ({self.runner})")
        self.runner = runner_class(self, *args, **kwargs)

        # Attach the runner to the shape class so that the shape class can access user count state
        if self.shape_class:
            self.shape_class.runner = self.runner

        return self.runner

    def create_local_runner(self) -> LocalRunner:
        """
        Create a :class:`LocalRunner <locust.runners.LocalRunner>` instance for this Environment
        """
        return self._create_runner(LocalRunner)

    def create_master_runner(self, master_bind_host="*", master_bind_port=5557) -> MasterRunner:
        """
        Create a :class:`MasterRunner <locust.runners.MasterRunner>` instance for this Environment

        :param master_bind_host: Interface/host that the master should use for incoming worker connections.
                                 Defaults to "*" which means all interfaces.
        :param master_bind_port: Port that the master should listen for incoming worker connections on
        """
        return self._create_runner(
            MasterRunner,
            master_bind_host=master_bind_host,
            master_bind_port=master_bind_port,
        )

    def create_worker_runner(self, master_host: str, master_port: int) -> WorkerRunner:
        """
        Create a :class:`WorkerRunner <locust.runners.WorkerRunner>` instance for this Environment

        :param master_host: Host/IP of a running master node
        :param master_port: Port on master node to connect to
        """
        # Create a new RequestStats with use_response_times_cache set to False to save some memory
        # and CPU cycles, since the response_times_cache is not needed for Worker nodes
        self.stats = RequestStats(use_response_times_cache=False)
        return self._create_runner(
            WorkerRunner,
            master_host=master_host,
            master_port=master_port,
        )

    def create_web_ui(
        self,
        host="",
        port=8089,
        web_base_path: str | None = None,
        web_login: bool = False,
        tls_cert: str | None = None,
        tls_key: str | None = None,
        stats_csv_writer: StatsCSV | None = None,
        delayed_start=False,
        userclass_picker_is_active=False,
        build_path: str | None = None,
    ) -> WebUI:
        """
        Creates a :class:`WebUI <locust.web.WebUI>` instance for this Environment and start running the web server

        :param host: Host/interface that the web server should accept connections to. Defaults to ""
                     which means all interfaces
        :param port: Port that the web server should listen to
        :param web_login: If provided, an authentication page will protect the app
        :param tls_cert: An optional path (str) to a TLS cert. If this is provided the web UI will be
                         served over HTTPS
        :param tls_key: An optional path (str) to a TLS private key. If this is provided the web UI will be
                        served over HTTPS
        :param stats_csv_writer: `StatsCSV <stats_csv.StatsCSV>` instance.
        :param delayed_start: Whether or not to delay starting web UI until `start()` is called. Delaying web UI start
                              allows for adding Flask routes or Blueprints before accepting requests, avoiding errors.
        """
        self.web_ui = WebUI(
            self,
            host,
            port,
            web_login=web_login,
            tls_cert=tls_cert,
            tls_key=tls_key,
            stats_csv_writer=stats_csv_writer,
            delayed_start=delayed_start,
            userclass_picker_is_active=userclass_picker_is_active,
            build_path=build_path,
            web_base_path=web_base_path,
        )
        return self.web_ui

    def update_user_class(self, user_settings):
        if isinstance(self.runner, MasterRunner):
            self.runner.send_message("update_user_class", user_settings)

        user_class_name = user_settings.get("user_class_name")
        user_class = self.available_user_classes[user_class_name]
        user_tasks = self.available_user_tasks[user_class_name]

        for key, value in user_settings.items():
            if key not in ["user_class_name", "tasks"]:
                setattr(user_class, key, value)
            if key == "tasks":
                user_class.tasks = [task for task in user_tasks if task.__name__ in value]

    def update_worker_logs(self, worker_log_report):
        if worker_log_report.get("worker_id", None):
            self.worker_logs[worker_log_report.get("worker_id")] = worker_log_report.get("logs", [])

    def _filter_tasks_by_tags(self) -> None:
        """
        Filter the tasks on all the user_classes recursively, according to the tags and
        exclude_tags attributes
        """
        if getattr(self, "_tasks_filtered", False):
            return  # only filter once
        self._tasks_filtered = True

        if self.tags is not None:
            tags = set(self.tags)
        elif self.parsed_options and getattr(self.parsed_options, "tags", False):
            tags = set(self.parsed_options.tags)
        else:
            tags = None

        if self.exclude_tags is not None:
            exclude_tags = set(self.exclude_tags)
        elif self.parsed_options and getattr(self.parsed_options, "exclude_tags", False):
            exclude_tags = set(self.parsed_options.exclude_tags)
        else:
            exclude_tags = None

        for user_class in self.user_classes:
            filter_tasks_by_tags(user_class, tags, exclude_tags)

    def _remove_user_classes_with_weight_zero(self) -> None:
        """
        Remove user classes having a weight of zero.
        """
        if len(self.user_classes) == 0:
            # Preserve previous behaviour that allowed no user classes to be specified.
            return
        filtered_user_classes = [
            user_class for user_class in self.user_classes if user_class.weight > 0 or user_class.fixed_count > 0
        ]
        if len(filtered_user_classes) == 0:
            # TODO: Better exception than `ValueError`?
            raise ValueError("There are no users with weight > 0.")
        self.user_classes[:] = filtered_user_classes

    def assign_equal_weights(self) -> None:
        """
        Update the user classes such that each user runs their specified tasks with equal
        probability.
        """
        for u in self.user_classes:
            u.weight = 1
            user_tasks: list[TaskSet | Callable] = []
            tasks_frontier = u.tasks
            while len(tasks_frontier) != 0:
                t = tasks_frontier.pop()
                if isinstance(t, TaskHolder):
                    tasks_frontier.extend(t.tasks)
                elif callable(t):
                    if t not in user_tasks:
                        user_tasks.append(t)
                else:
                    raise ValueError("Unrecognized task type in user")
            u.tasks = user_tasks

    def _validate_user_class_name_uniqueness(self):
        # Validate there's no class with the same name but in different modules
        if len({user_class.__name__ for user_class in self.user_classes}) != len(self.user_classes):
            raise ValueError(
                "The following user classes have the same class name: {}".format(
                    ", ".join(map(methodcaller("fullname"), self.user_classes))
                )
            )

    def _validate_shape_class_instance(self):
        if self.shape_class is not None and not isinstance(self.shape_class, LoadTestShape):
            raise ValueError(
                f"shape_class should be instance of LoadTestShape or subclass LoadTestShape, but got: {self.shape_class}"
            )

    @property
    def user_classes_by_name(self) -> dict[str, type[User]]:
        return {u.__name__: u for u in self.user_classes}

parte 04

from __future__ import annotations

import locust
import locust.log
from locust import argument_parser
from locust.env import Environment
from locust.exception import CatchResponseError, RescheduleTask

import inspect
import os
from datetime import UTC, datetime
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from locust import User


def _print_t(s):
    """
    Print something with a tab instead of newline at the end
    """
    print(str(s), end="\t")


class PrintListener:
    """
    Print every response (useful when debugging a single locust)
    """

    def __init__(
        self,
        env: Environment,
        include_length=False,
        include_time=False,
        include_context=False,
        include_payload=False,
    ):
        env.events.request.add_listener(self.on_request)

        self.include_length = "length\t" if include_length else ""
        self.include_time = "time                    \t" if include_time else ""
        self.include_context = "context\t" if include_context else ""
        self.include_payload = "payload\t" if include_payload else ""

        print(
            f"\n{self.include_time}type\t{'name'.ljust(50)}\tresp_ms\t{self.include_length}exception\t{self.include_context}\t{self.include_payload}"
        )

    def on_request(
        self,
        request_type,
        name,
        response_time,
        response_length,
        exception,
        context: dict,
        start_time=None,
        response=None,
        **_kwargs,
    ):
        if exception:
            if isinstance(exception, RescheduleTask):
                pass
            if isinstance(exception, CatchResponseError):
                e = str(exception)
            else:
                try:
                    e = repr(exception)
                except AttributeError:
                    e = f"{exception.__class__} (and it has no string representation)"
            errortext = e[:500].replace("\n", " ")
        else:
            errortext = ""

        if response_time is None:
            response_time = -1
        n = name.ljust(30) if name else ""

        if self.include_time:
            if start_time:
                _print_t(datetime.fromtimestamp(start_time, tz=UTC))
            else:
                _print_t(datetime.now())

        _print_t(request_type)
        _print_t(n.ljust(50))
        _print_t(str(round(response_time)).ljust(7))

        if self.include_length:
            _print_t(response_length)

        _print_t(errortext.ljust(9))

        if self.include_context:
            _print_t(context or "")

        if self.include_payload:
            _print_t(response._request.payload)

        print()


_env: Environment | None = None  # minimal Environment for debugging


def run_single_user(
    user_class: type[User],
    include_length=False,
    include_time=False,
    include_context=False,
    include_payload=False,
    loglevel: str | None = "WARNING",
):
    """
    Runs a single User. Useful when you want to run a debugger.

    It creates in a new locust :py:attr:`Environment <locust.env.Environment>` and triggers any ``init`` or ``test_start`` :ref:`events <extending_locust>` as normal.

    It does **not** trigger ``test_stop`` or ``quit`` when you quit the debugger.

    It prints some info about every request to stdout, and you can get additional info using the `include_*` flags

    It also initiates logging on WARNING level (not INFO, because it could interfere with the printing of requests),
    but you can change that by passing a log level (or disabling logging entirely by passing None)
    """
    global _env

    if loglevel:
        locust.log.setup_logging(loglevel)

    if not _env:
        options = argument_parser.get_parser().parse_args()

        # in case your test goes looking for the file name of your locustfile
        frame = inspect.stack()[1]
        locustfile = os.path.basename(frame[0].f_code.co_filename)
        options.locustfile = locustfile

        _env = Environment(events=locust.events, locustfile=locustfile, host=options.host, parsed_options=options)

        # log requests to stdout
        PrintListener(
            _env,
            include_length=include_length,
            include_time=include_time,
            include_context=include_context,
            include_payload=include_payload,
        )
        # fire various events (quit and test_stop will never get called, sorry about that)
        _env.events.init.fire(environment=_env, runner=None, web_ui=None)
        # uncaught events will be suppressed, so check if that happened
        if locust.log.unhandled_greenlet_exception:
            os._exit(1)

    # do the things that the Runner usually does
    _env.user_classes = [user_class]
    _env._filter_tasks_by_tags()
    _env.events.test_start.fire(environment=_env)
    if _env.host:
        user_class.host = _env.host

    # create a single user
    user = user_class(_env)
    setattr(_env, "single_user_instance", user)  # if you happen to need access to this from the Environment instance
    user.run()


import warnings

# Show deprecation warnings
warnings.filterwarnings("always", category=DeprecationWarning, module="locust")


def check_for_deprecated_task_set_attribute(class_dict):
    from locust.user.task import TaskSet

    if "task_set" in class_dict:
        task_set = class_dict["task_set"]
        if issubclass(task_set, TaskSet) and not hasattr(task_set, "locust_task_weight"):
            warnings.warn(
                "Usage of User.task_set is deprecated since version 1.0. Set the tasks attribute instead "
                f"(tasks = [{task_set.__name__}])",
                DeprecationWarning,
            )


def deprecated_locust_meta_class(deprecation_message):
    class MetaClass(type):
        def __new__(mcs, classname, bases, class_dict):
            if classname in ["DeprecatedLocustClass", "DeprecatedHttpLocustClass", "DeprecatedFastHttpLocustClass"]:
                return super().__new__(mcs, classname, bases, class_dict)
            else:
                raise ImportError(deprecation_message)

    return MetaClass


# PEP 484 specifies "Generic metaclasses are not supported", see https://github.com/python/mypy/issues/3602, ignore typing errors
class DeprecatedLocustClass(
    metaclass=deprecated_locust_meta_class(  # type: ignore
        "The Locust class has been renamed to User in version 1.0. "
        "For more info see: https://docs.locust.io/en/latest/changelog.html#changelog-1-0"
    )
):
    pass


class DeprecatedHttpLocustClass(
    metaclass=deprecated_locust_meta_class(  # type: ignore
        "The HttpLocust class has been renamed to HttpUser in version 1.0. "
        "For more info see: https://docs.locust.io/en/latest/changelog.html#changelog-1-0"
    )
):
    pass


class DeprecatedFastHttpLocustClass(
    metaclass=deprecated_locust_meta_class(  # type: ignore
        "The FastHttpLocust class has been renamed to FastHttpUser in version 1.0. "
        "For more info see: https://docs.locust.io/en/latest/changelog.html#changelog-1-0"
    )
):
    pass

import functools
from time import time


def memoize(timeout, dynamic_timeout=False):
    """
    Memoization decorator with support for timeout.

    If dynamic_timeout is set, the cache timeout is doubled if the cached function
    takes longer time to run than the timeout time
    """
    cache = {"timeout": timeout}

    def decorator(func):
        @functools.wraps(func)
        def wrapper(*args, **kwargs):
            start = time()
            if (not "time" in cache) or (start - cache["time"] > cache["timeout"]):
                # cache miss
                cache["result"] = func(*args, **kwargs)
                cache["time"] = time()
                if dynamic_timeout and cache["time"] - start > cache["timeout"]:
                    cache["timeout"] *= 2
            return cache["result"]

        def clear_cache():
            if "time" in cache:
                del cache["time"]
            if "result" in cache:
                del cache["result"]

        wrapper.clear_cache = clear_cache
        return wrapper

    return decorator
from datetime import UTC, datetime


def format_utc_timestamp(unix_timestamp):
    return datetime.fromtimestamp(int(unix_timestamp), UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def format_safe_timestamp(unix_timestamp):
    return datetime.fromtimestamp(int(unix_timestamp)).strftime("%Y-%m-%d-%Hh%M")


def format_duration(start_time, end_time):
    seconds = int(end_time) - int(start_time)
    days = seconds // 86400
    hours = (seconds % 86400) // 3600
    minutes = (seconds % 3600) // 60
    seconds = seconds % 60

    time_parts = [(days, "day"), (hours, "hour"), (minutes, "minute"), (seconds, "second")]

    parts = [f"{value} {label}{'s' if value != 1 else ''}" for value, label in time_parts if value > 0]

    return " and ".join(filter(None, [", ".join(parts[:-1])] + parts[-1:])) if parts else "0 seconds"


from __future__ import annotations

import inspect
from collections import defaultdict
from json import dumps

from .task import TaskSet
from .users import User


def print_task_ratio(user_classes, num_users, total):
    """
    This function calculates the task ratio of users based on the user total count.
    """
    d = get_ratio(user_classes, _calc_distribution(user_classes, num_users), total)
    _print_task_ratio(d)


def print_task_ratio_json(user_classes, num_users):
    d = _calc_distribution(user_classes, num_users)
    task_data = {
        "per_class": get_ratio(user_classes, d, False),
        "total": get_ratio(user_classes, d, True),
    }

    print(dumps(task_data, indent=4))


def _calc_distribution(user_classes, num_users):
    fixed_count = sum(u.fixed_count for u in user_classes if u.fixed_count)
    total_weight = sum(u.weight for u in user_classes if not u.fixed_count)
    num_users = num_users or (total_weight if not fixed_count else 1)
    weighted_count = num_users - fixed_count
    weighted_count = max(0, weighted_count)
    user_classes_count = {}

    for u in user_classes:
        count = u.fixed_count or (u.weight / total_weight) * weighted_count
        user_classes_count[u.__name__] = round(count)

    return user_classes_count


def _print_task_ratio(x, level=0):
    padding = 2 * " " * level
    for k, v in x.items():
        ratio = v.get("ratio", 1)
        print(" %-10s %-50s" % (padding + "%-6.1f" % (ratio * 100), padding + k))
        if "tasks" in v:
            _print_task_ratio(v["tasks"], level + 1)


def get_ratio(user_classes: list[type[User]], user_spawned: dict[str, int], total: bool) -> dict[str, dict[str, float]]:
    user_count = sum(user_spawned.values()) or 1
    ratio_percent: dict[type[User], float] = {u: user_spawned.get(u.__name__, 0) / user_count for u in user_classes}

    task_dict: dict[str, dict[str, float]] = {}
    for u, r in ratio_percent.items():
        d = {"ratio": r}
        d["tasks"] = _get_task_ratio(u.tasks, total, r)
        task_dict[u.__name__] = d

    return task_dict


def _get_task_ratio(tasks, total, parent_ratio):
    parent_ratio = parent_ratio if total else 1.0
    ratio = defaultdict(int)
    for task in tasks:
        ratio[task] += 1

    ratio_percent = {t: r * parent_ratio / len(tasks) for t, r in ratio.items()}

    task_dict = {}
    for t, r in ratio_percent.items():
        d = {"ratio": r}
        if inspect.isclass(t) and issubclass(t, TaskSet):
            d["tasks"] = _get_task_ratio(t.tasks, total, r)
        task_dict[t.__name__] = d

    return task_dict


from __future__ import annotations

from locust.clients import HttpSession
from locust.exception import CatchResponseError, StopTest, StopUser
from locust.user.task import (
    LOCUST_STATE_RUNNING,
    LOCUST_STATE_STOPPING,
    LOCUST_STATE_WAITING,
    DefaultTaskSet,
    TaskSet,
    get_tasks_from_base_classes,
)
from locust.user.wait_time import constant
from locust.util import deprecation

import logging
import sys
import time
import traceback
from collections.abc import Callable
from typing import TYPE_CHECKING, final

from gevent import GreenletExit, greenlet
from gevent.pool import Group
from geventhttpclient.useragent import ConnectionError
from requests.exceptions import RequestException
from urllib3 import PoolManager

if sys.version_info >= (3, 12):
    from typing import override
else:
    from typing_extensions import override

if TYPE_CHECKING:
    import pytest

logger = logging.getLogger(__name__)


class UserMeta(type):
    """
    Meta class for the main User class. It's used to allow User classes to specify task execution
    ratio using an {task:int} dict, or a [(task0,int), ..., (taskN,int)] list.
    """

    def __new__(mcs, classname, bases, class_dict):
        # gather any tasks that is declared on the class (or it's bases)
        tasks = get_tasks_from_base_classes(bases, class_dict)
        class_dict["tasks"] = tasks

        if not class_dict.get("abstract"):
            # Not a base class
            class_dict["abstract"] = False

        deprecation.check_for_deprecated_task_set_attribute(class_dict)

        return type.__new__(mcs, classname, bases, class_dict)


class User(metaclass=UserMeta):
    """
    Represents a "user" which is to be spawned and attack the system that is to be load tested.

    The behaviour of this user is defined by its tasks. Tasks can be declared either directly on the
    class by using the :py:func:`@task decorator <locust.task>` on methods, or by setting
    the :py:attr:`tasks attribute <locust.User.tasks>`.

    This class should usually be subclassed by a class that defines some kind of client. For
    example when load testing an HTTP system, you probably want to use the
    :py:class:`HttpUser <locust.HttpUser>` class.
    """

    host: str | None = None
    """Base hostname to swarm. i.e: http://127.0.0.1:1234"""

    min_wait = None
    """Deprecated: Use wait_time instead. Minimum waiting time between the execution of locust tasks"""

    max_wait = None
    """Deprecated: Use wait_time instead. Maximum waiting time between the execution of locust tasks"""

    wait_time = constant(0)
    """
    Method that returns the time (in seconds) between the execution of locust tasks.
    Can be overridden for individual TaskSets.

    Example::

        from locust import User, between
        class MyUser(User):
            wait_time = between(3, 25)
    """

    wait_function = None
    """
    .. warning::

        DEPRECATED: Use wait_time instead. Note that the new wait_time method should return seconds and not milliseconds.

    Method that returns the time between the execution of locust tasks in milliseconds
    """

    tasks: list[TaskSet | Callable] = []
    """
    Collection of python callables and/or TaskSet classes that the Locust user(s) will run.

    If tasks is a list, the task to be performed will be picked randomly.

    If tasks is a *(callable,int)* list of two-tuples, or a {callable:int} dict,
    the task to be performed will be picked randomly, but each task will be weighted
    according to its corresponding int value. So in the following case, *ThreadPage* will
    be fifteen times more likely to be picked than *write_post*::

        class ForumPage(TaskSet):
            tasks = {ThreadPage:15, write_post:1}
    """

    weight: float = 1
    """Probability of user class being chosen. The higher the weight, the greater the chance of it being chosen."""

    fixed_count: int = 0
    """
    If the value > 0, the weight property will be ignored and the 'fixed_count'-instances will be spawned.
    These Users are spawned first. If the total target count (specified by the --users arg) is not enough
    to spawn all instances of each User class with the defined property, the final count of each User is undefined.
    """

    abstract: bool = True
    """If abstract is True, the class is meant to be subclassed, and locust will not spawn users of this class during a test."""

    def __init__(self, environment) -> None:
        super().__init__()
        self.environment = environment
        """A reference to the :py:class:`Environment <locust.env.Environment>` in which this user is running"""
        self._state: str | None = None
        self._greenlet: greenlet.Greenlet | None = None
        self._group: Group
        self._taskset_instance: TaskSet | None = None
        self._cp_last_run: float = time.time()  # used by constant_pacing wait_time
        self._cp_last_wait_time: float = 0  # used by constant_pacing wait_time

    def on_start(self) -> None:
        """
        Called when a User starts running.
        """
        pass

    def on_stop(self):
        """
        Called when a User stops running (is killed)
        """
        pass

    @final
    def run(self):
        self._state = LOCUST_STATE_RUNNING
        self._taskset_instance = DefaultTaskSet(self)
        try:
            # run the User on_start method, if it has one
            try:
                self.on_start()
            except Exception as e:
                # unhandled exceptions inside tasks are logged in TaskSet.run, but since we're not yet there...
                logger.error("%s\n%s", e, traceback.format_exc())
                raise

            self._taskset_instance.run()
        except (GreenletExit, StopUser, StopTest):
            # run the on_stop method, if it has one
            self.on_stop()

    def wait(self):
        """
        Make the running user sleep for a duration defined by the User.wait_time
        function.

        The user can also be killed gracefully while it's sleeping, so calling this
        method within a task makes it possible for a user to be killed mid-task even if you've
        set a stop_timeout. If this behaviour is not desired, you should make the user wait using
        gevent.sleep() instead.
        """
        self._taskset_instance.wait()

    def start(self, group: Group):
        """
        Start a greenlet that runs this User instance.

        :param group: Group instance where the greenlet will be spawned.
        :type group: gevent.pool.Group
        :returns: The spawned greenlet.
        """

        def run_user(user):
            """
            Main function for User greenlet. It's important that this function takes the user
            instance as an argument, since we use greenlet_instance.args[0] to retrieve a reference to the
            User instance.
            """
            user.run()

        self._greenlet = group.spawn(run_user, self)
        self._group = group
        return self._greenlet

    def stop(self, force: bool = False):
        """
        Stop the user greenlet.

        :param force: If False (the default) the stopping is done gracefully by setting the state to LOCUST_STATE_STOPPING
                      which will make the User instance stop once any currently running task is complete and on_stop
                      methods are called. If force is True the greenlet will be killed immediately.
        :returns: True if the greenlet was killed immediately, otherwise False
        """
        if force or self._state == LOCUST_STATE_WAITING:
            self._group.killone(self._greenlet)
            return True
        elif self._state == LOCUST_STATE_RUNNING:
            self._state = LOCUST_STATE_STOPPING
            return False
        else:
            raise Exception(f"Tried to stop User in an unexpected state: {self._state}. This should never happen.")

    @property
    def group(self):
        return self._group

    @property
    def greenlet(self):
        return self._greenlet

    def context(self) -> dict:
        """
        Adds the returned value (a dict) to the context for :ref:`request event <request_context>`.
        Override this in your User class to customize the context.
        """
        return {}

    @classmethod
    def json(cls):
        return {
            "host": cls.host,
            "weight": cls.weight,
            "fixed_count": cls.fixed_count,
            "tasks": [task.__name__ for task in cls.tasks],
        }

    @classmethod
    def fullname(cls) -> str:
        """Fully qualified name of the user class, e.g. my_package.my_module.MyUserClass"""
        return ".".join(filter(lambda x: x != "<locals>", (cls.__module__ + "." + cls.__qualname__).split(".")))


class HttpUser(User):
    """
    Represents an HTTP "user" which is to be spawned and attack the system that is to be load tested.

    The behaviour of this user is defined by its tasks. Tasks can be declared either directly on the
    class by using the :py:func:`@task decorator <locust.task>` on methods, or by setting
    the :py:attr:`tasks attribute <locust.User.tasks>`.

    This class creates a *client* attribute on instantiation which is an HTTP client with support
    for keeping a user session between requests.
    """

    abstract: bool = True
    """If abstract is True, the class is meant to be subclassed, and users will not choose this locust during a test"""

    pool_manager: PoolManager | None = None
    """Connection pool manager to use. If not given, a new manager is created per single user."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        if self.host is None:
            raise StopTest(
                "You must specify the base host. Either in the host attribute in the User class, or on the command line using the --host option."
            )

        self.client = HttpSession(
            base_url=self.host,
            request_event=self.environment.events.request,
            user=self,
            pool_manager=self.pool_manager,
        )
        """
        Instance of HttpSession that is created upon instantiation of Locust.
        The client supports cookies, and therefore keeps the session between HTTP requests.
        """
        self.client.trust_env = False


class PytestUser(User):
    abstract = True
    functions: list[pytest.Function]
    fixtures: list

    @override
    def run(self):  # type: ignore[override] # We actually DO want to change the default User behavior
        self._state = LOCUST_STATE_RUNNING
        self.fixtures = [next(f.fixturedef.func(self)) for f in self.functions]  # type: ignore[attr-defined]
        while True:
            for i in range(len(self.fixtures)):
                try:  # try-except is for supporting .raise_for_status() in tests
                    self.functions[i].obj(self.fixtures[i])
                except RequestException as e:
                    if isinstance(e, ValueError):  # things like MissingSchema etc, lets not catch that
                        raise
                    logger.debug("%s\n%s", e, traceback.format_exc())
                except CatchResponseError as e:
                    logger.debug("%s\n%s", e, traceback.format_exc())
                except ConnectionError as e:
                    logger.debug("%s\n%s", e, traceback.format_exc())











import gevent.monkey

gevent.monkey.patch_all()
import grpc.experimental.gevent as grpc_gevent

grpc_gevent.init_gevent()

from locust import User, events

import time
from abc import ABC, abstractmethod
from typing import Any

from pymilvus import CollectionSchema, MilvusClient
from pymilvus.milvus_client import IndexParams


class BaseClient(ABC):
    @abstractmethod
    def close(self) -> None:
        pass

    @abstractmethod
    def create_collection(self, schema, index_params, **kwargs) -> None:
        pass

    @abstractmethod
    def insert(self, data) -> dict[str, Any]:
        pass

    @abstractmethod
    def upsert(self, data) -> dict[str, Any]:
        pass

    @abstractmethod
    def search(
        self,
        data,
        anns_field,
        limit,
        filter="",
        search_params=None,
        output_fields=None,
        calculate_recall=False,
        ground_truth=None,
    ) -> dict[str, Any]:
        pass

    @abstractmethod
    def hybrid_search(self, reqs, ranker, limit, output_fields=None) -> dict[str, Any]:
        pass

    @abstractmethod
    def query(self, filter, output_fields=None) -> dict[str, Any]:
        pass

    @abstractmethod
    def delete(self, filter) -> dict[str, Any]:
        pass


class MilvusV2Client(BaseClient):
    """Milvus v2 Python SDK Client Wrapper"""

    def __init__(self, uri, collection_name, token="root:Milvus", db_name="default", timeout=60):
        self.uri = uri
        self.collection_name = collection_name
        self.token = token
        self.db_name = db_name
        self.timeout = timeout

        # Initialize MilvusClient v2
        self.client = MilvusClient(
            uri=self.uri,
            token=self.token,
            db_name=self.db_name,
            timeout=self.timeout,
        )

    def close(self):
        self.client.close()

    def create_collection(self, schema, index_params, **kwargs):
        self.client.create_collection(
            collection_name=self.collection_name,
            schema=schema,
            index_params=index_params,
            **kwargs,
        )

    def insert(self, data):
        start = time.time()
        try:
            result = self.client.insert(collection_name=self.collection_name, data=data)
            total_time = (time.time() - start) * 1000
            return {"success": True, "response_time": total_time, "result": result}
        except Exception as e:
            return {
                "success": False,
                "response_time": (time.time() - start) * 1000,
                "exception": e,
            }

    def upsert(self, data):
        start = time.time()
        try:
            result = self.client.upsert(collection_name=self.collection_name, data=data)
            total_time = (time.time() - start) * 1000
            return {"success": True, "response_time": total_time, "result": result}
        except Exception as e:
            return {
                "success": False,
                "response_time": (time.time() - start) * 1000,
                "exception": e,
            }

    def search(
        self,
        data,
        anns_field,
        limit,
        filter="",
        search_params=None,
        output_fields=None,
        calculate_recall=False,
        ground_truth=None,
    ):
        if output_fields is None:
            output_fields = ["id"]

        start = time.time()
        try:
            result = self.client.search(
                collection_name=self.collection_name,
                data=data,
                anns_field=anns_field,
                filter=filter,
                limit=limit,
                search_params=search_params,
                output_fields=output_fields,
            )
            total_time = (time.time() - start) * 1000
            empty = len(result) == 0 or all(len(r) == 0 for r in result)

            # Prepare base result
            search_result = {
                "success": not empty,
                "response_time": total_time,
                "empty": empty,
                "result": result,
            }

            # Calculate recall if requested
            if calculate_recall and ground_truth is not None and not empty:
                recall_value = self.get_recall(result, ground_truth, limit)
                search_result["recall"] = recall_value

            return search_result
        except Exception as e:
            return {
                "success": False,
                "response_time": (time.time() - start) * 1000,
                "exception": e,
            }

    def hybrid_search(self, reqs, ranker, limit, output_fields=None):
        if output_fields is None:
            output_fields = ["id"]

        start = time.time()
        try:
            result = self.client.hybrid_search(
                collection_name=self.collection_name,
                reqs=reqs,
                ranker=ranker,
                limit=limit,
                output_fields=output_fields,
                timeout=self.timeout,
            )
            total_time = (time.time() - start) * 1000
            empty = len(result) == 0 or all(len(r) == 0 for r in result)

            # Prepare base result
            search_result = {
                "success": not empty,
                "response_time": total_time,
                "empty": empty,
                "result": result,
            }

            return search_result
        except Exception as e:
            return {
                "success": False,
                "response_time": (time.time() - start) * 1000,
                "exception": e,
            }

    @staticmethod
    def get_recall(search_results, ground_truth, limit=None):
        """Calculate recall for V2 client search results."""
        try:
            # Extract IDs from V2 search results
            retrieved_ids = []
            if isinstance(search_results, list) and len(search_results) > 0:
                # search_results[0] contains the search results for the first query
                for hit in search_results[0] if isinstance(search_results[0], list) else search_results:
                    if isinstance(hit, dict) and "id" in hit:
                        retrieved_ids.append(hit["id"])
                    elif hasattr(hit, "get"):
                        retrieved_ids.append(hit.get("id"))

            # Apply limit if specified
            if limit is None:
                limit = len(retrieved_ids)

            if len(ground_truth) < limit:
                raise ValueError(f"Ground truth length is less than limit: {len(ground_truth)} < {limit}")

            # Calculate recall
            ground_truth_set = set(ground_truth[:limit])
            retrieved_set = set(retrieved_ids)
            intersect = len(ground_truth_set.intersection(retrieved_set))
            return intersect / len(ground_truth_set)

        except Exception:
            return 0.0

    def query(self, filter, output_fields=None):
        if output_fields is None:
            output_fields = ["id"]

        start = time.time()
        try:
            result = self.client.query(
                collection_name=self.collection_name,
                filter=filter,
                output_fields=output_fields,
            )
            total_time = (time.time() - start) * 1000
            empty = len(result) == 0
            return {
                "success": not empty,
                "response_time": total_time,
                "empty": empty,
                "result": result,
            }
        except Exception as e:
            return {
                "success": False,
                "response_time": (time.time() - start) * 1000,
                "exception": e,
            }

    def delete(self, filter):
        start = time.time()
        try:
            result = self.client.delete(collection_name=self.collection_name, filter=filter)
            total_time = (time.time() - start) * 1000
            return {"success": True, "response_time": total_time, "result": result}
        except Exception as e:
            return {
                "success": False,
                "response_time": (time.time() - start) * 1000,
                "exception": e,
            }


# ----------------------------------
# Locust User wrapper
# ----------------------------------


class MilvusUser(User):
    """Locust User implementation for Milvus operations.

    This class wraps the MilvusV2Client implementation and translates
    client method results into Locust request events so that performance
    statistics are collected properly.

    Parameters
    ----------
    host : str
        Milvus server URI, e.g. ``"http://localhost:19530"``.
    collection_name : str
        The name of the collection to operate on.
    **client_kwargs
        Additional keyword arguments forwarded to the client.
    """

    abstract = True

    def __init__(
        self,
        environment,
        uri: str = "http://localhost:19530",
        token: str = "root:Milvus",
        collection_name: str = "test_collection",
        db_name: str = "default",
        timeout: int = 60,
        schema: CollectionSchema | None = None,
        index_params: IndexParams | None = None,
        **kwargs,  # enable_dynamic_field, num_shards, consistency_level etc. ref: https://milvus.io/api-reference/pymilvus/v2.6.x/MilvusClient/Collections/create_collection.md
    ):
        super().__init__(environment)

        if uri is None:
            raise ValueError("'uri' must be provided for MilvusUser")
        if collection_name is None:
            raise ValueError("'collection_name' must be provided for MilvusUser")

        self.client_type = "milvus"
        self.client = MilvusV2Client(
            uri=uri,
            token=token,
            collection_name=collection_name,
            db_name=db_name,
            timeout=timeout,
        )
        if schema is not None:
            self.client.create_collection(schema=schema, index_params=index_params, **kwargs)

    @staticmethod
    def _fire_event(request_type: str, name: str, result: dict[str, Any]):
        """Emit a Locust request event from a Milvus client result dict."""
        response_time = int(result.get("response_time", 0))
        events.request.fire(
            request_type=f"{request_type}",
            name=name,
            response_time=response_time,
            response_length=0,
            exception=result.get("exception"),
        )

    @staticmethod
    def _fire_recall_event(request_type: str, name: str, result: dict[str, Any]):
        """Emit a Locust request event for recall metric using recall value instead of response time."""
        recall_value = result.get("recall", 0.0)
        # Use recall value as response_time for metric display (scaled by 100 for better visualization) percentage
        response_time_as_recall = int(recall_value * 100)
        events.request.fire(
            request_type=f"{request_type}",
            name=name,
            response_time=response_time_as_recall,
            response_length=result.get("retrieved_count", 0),
            exception=result.get("exception"),
        )

    def insert(self, data):
        result = self.client.insert(data)
        self._fire_event(self.client_type, "insert", result)
        return result

    def upsert(self, data):
        result = self.client.upsert(data)
        self._fire_event(self.client_type, "upsert", result)
        return result

    def search(
        self,
        data,
        anns_field,
        limit,
        filter="",
        search_params=None,
        output_fields=None,
        calculate_recall=False,
        ground_truth=None,
    ):
        result = self.client.search(
            data,
            anns_field,
            limit,
            filter=filter,
            search_params=search_params,
            output_fields=output_fields,
            calculate_recall=calculate_recall,
            ground_truth=ground_truth,
        )
        # Fire search event
        self._fire_event(self.client_type, "search", result)

        # Fire recall event if recall was calculated
        if calculate_recall and "recall" in result:
            self._fire_recall_event(self.client_type, "recall", result)

        return result

    def hybrid_search(self, reqs, ranker, limit, output_fields=None):
        result = self.client.hybrid_search(reqs, ranker, limit, output_fields)
        self._fire_event(self.client_type, "hybrid_search", result)
        return result

    def query(self, filter, output_fields=None):
        result = self.client.query(
            filter=filter,
            output_fields=output_fields,
        )
        self._fire_event(self.client_type, "query", result)
        return result

    def delete(self, filter):
        result = self.client.delete(filter)
        self._fire_event(self.client_type, "delete", result)
        return result

    def on_stop(self):
        self.client.close()




"""
This file contains a benchmark to validate the performance of Locust itself.
More precisely, the performance of the `UsersDispatcher` class which is responsible
for calculating the distribution of users on each worker. This benchmark is to be used
by people working on Locust's development.
"""

from locust import User
from locust.dispatch import UsersDispatcher
from locust.runners import WorkerNode

import argparse
import gc
import itertools
import statistics
import time

from prettytable import PrettyTable

NUMBER_OF_USER_CLASSES: int = 1000
USER_CLASSES: list[type[User]] = []
WEIGHTS = list(range(1, NUMBER_OF_USER_CLASSES + 1))

for i, x in enumerate(WEIGHTS):
    exec(f"class User{i}(User): weight = {x}")

# Equivalent to:
#
# class User0(User):
#     weight = 5
#
# class User1(User):
#     weight = 55
# .
# .
# .

exec("USER_CLASSES = [" + ",".join(f"User{i}" for i in range(len(WEIGHTS))) + "]")
# Equivalent to:
#
# USER_CLASSES = [
#     User0,
#     User1,
#     .
#     .
#     .
# ]


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("-f", "--full-benchmark", action="store_true", help="run benchmark on full test matrix")
    parser.add_argument(
        "-i",
        "--include-fixed-users",
        action="store_true",
        help="add test cases when 50 percent of users use User.fixed_count instead of User.weight",
    )
    parser.add_argument("-r", "--repeat", default=1, type=int, help="number of test cases with the same parameters")
    parser.add_argument("-s", "--save-output", action="store_true", help="save test results to files")
    args = parser.parse_args()

    now = time.time()

    worker_count_cases = [10, 100, 1000]
    user_count_cases = [10_000, 100_000, 1_000_000]
    number_of_user_classes_cases = [1, 30, 1000]
    spawn_rate_cases = [100, 10_000]
    fixed_count_cases = [False, True] if args.include_fixed_users else [False]
    # [0% fixed_count users, 50% fixed_count users] if args.mixed_user_types else [0% fixed_count users]
    repeat_cases = list(range(1, args.repeat + 1))

    if not args.full_benchmark:
        worker_count_cases = [max(worker_count_cases)]
        user_count_cases = [max(user_count_cases)]
        number_of_user_classes_cases = [max(number_of_user_classes_cases)]
        spawn_rate_cases = [max(spawn_rate_cases)]

    case_count = (
        len(worker_count_cases)
        * len(user_count_cases)
        * len(number_of_user_classes_cases)
        * len(spawn_rate_cases)
        * len(fixed_count_cases)
        * len(repeat_cases)
    )

    results = {}

    try:
        for case_index, (
            worker_count,
            user_count,
            number_of_user_classes,
            spawn_rate,
            fixed_users,
            iteration,
        ) in enumerate(
            itertools.product(
                worker_count_cases,
                user_count_cases,
                number_of_user_classes_cases,
                spawn_rate_cases,
                fixed_count_cases,
                repeat_cases,
            )
        ):
            workers = [WorkerNode(str(i)) for i in range(worker_count)]
            if fixed_users:
                sum_fixed_weight = 0
                for j in range(0, number_of_user_classes, 2):
                    sum_fixed_weight += USER_CLASSES[j].weight

                for j in range(0, number_of_user_classes, 2):  # set fixed_weights for 50% of users
                    USER_CLASSES[j].fixed_count = max(1, USER_CLASSES[j].weight // sum_fixed_weight)  # type: ignore # assigned .weight is int

            ts = time.process_time()
            users_dispatcher = UsersDispatcher(
                worker_nodes=workers,
                user_classes=USER_CLASSES[:number_of_user_classes],
            )
            instantiate_duration = time.process_time() - ts

            # Ramp-up
            gc.disable()
            ts = time.process_time()
            users_dispatcher.new_dispatch(target_user_count=user_count, spawn_rate=spawn_rate)
            new_dispatch_ramp_up_duration = time.process_time() - ts
            gc.enable()

            assert len(users_dispatcher.dispatch_iteration_durations) == 0
            users_dispatcher._wait_between_dispatch = 0
            all_dispatched_users_ramp_up = list(users_dispatcher)
            dispatch_iteration_durations_ramp_up = users_dispatcher.dispatch_iteration_durations[:]

            # Ramp-down
            gc.disable()
            ts = time.process_time()
            users_dispatcher.new_dispatch(target_user_count=0, spawn_rate=spawn_rate)
            new_dispatch_ramp_down_duration = time.process_time() - ts
            gc.enable()

            assert len(users_dispatcher.dispatch_iteration_durations) == 0
            users_dispatcher._wait_between_dispatch = 0
            all_dispatched_users_ramp_down = list(users_dispatcher)
            dispatch_iteration_durations_ramp_down = users_dispatcher.dispatch_iteration_durations[:]

            if fixed_users:
                for j in range(0, number_of_user_classes, 2):
                    USER_CLASSES[j].fixed_count = None

            cpu_ramp_up = "{:3.3f}/{:3.3f}/{:3.3f}".format(  # noqa: UP032
                1000 * statistics.mean(dispatch_iteration_durations_ramp_up),
                1000 * min(dispatch_iteration_durations_ramp_up),
                1000 * max(dispatch_iteration_durations_ramp_up),
            )  # noqa: UP032
            cpu_ramp_down = "{:3.3f}/{:3.3f}/{:3.3f}".format(  # noqa: UP032
                1000 * statistics.mean(dispatch_iteration_durations_ramp_down),
                1000 * min(dispatch_iteration_durations_ramp_down),
                1000 * max(dispatch_iteration_durations_ramp_down),
            )

            print(
                "{:04.0f}/{:04.0f} - {:,} workers - {:,} users - {} user classes - {:,} users/s - instantiate: {:.3f}ms - new_dispatch (ramp-up/ramp-down): {:.3f}ms/{:.3f}ms - cpu_ramp_up: {}ms - cpu_ramp_down: {}ms".format(  # noqa: UP032
                    case_index + 1,
                    case_count,
                    worker_count,
                    user_count,
                    number_of_user_classes,
                    spawn_rate,
                    instantiate_duration * 1000,
                    new_dispatch_ramp_up_duration * 1000,
                    new_dispatch_ramp_down_duration * 1000,
                    cpu_ramp_up,
                    cpu_ramp_down,
                )
            )

            results[(worker_count, user_count, number_of_user_classes, spawn_rate, fixed_users, iteration)] = (
                cpu_ramp_up,
                cpu_ramp_down,
            )

    finally:
        table = PrettyTable()
        table.field_names = [
            "Workers",
            "Users",
            "User Classes",
            "Spawn Rate",
            "Fixed Users",
            "Iteration",
            "Ramp-Up (avg/min/max) (ms)",
            "Ramp-Down (avg/min/max) (ms)",
        ]
        table.align["Workers"] = "l"
        table.align["Users"] = "l"
        table.align["User Classes"] = "l"
        table.align["Spawn Rate"] = "l"
        table.align["Fixed Users"] = "l"
        table.align["Iteration"] = "c"
        table.align["Ramp-Up (avg/min/max) (ms)"] = "c"
        table.align["Ramp-Down (avg/min/max) (ms)"] = "c"
        table.add_rows(
            [
                [
                    f"{worker_count:,}",
                    f"{user_count:,}",
                    number_of_user_classes,
                    f"{spawn_rate:,}",
                    "50%" if fixed_users else "0%",
                    iteration,
                    cpu_ramp_up,
                    cpu_ramp_down,
                ]
                for (worker_count, user_count, number_of_user_classes, spawn_rate, fixed_users, iteration), (
                    cpu_ramp_up,
                    cpu_ramp_down,
                ) in results.items()
            ]
        )
        print()
        print(table)

        if args.save_output:
            with open(f"results-dispatch-benchmarks-{int(now)}.txt", "w") as file:
                file.write(table.get_string())

            with open(f"results-dispatch-benchmarks-{int(now)}.json", "w") as file:
                file.write(table.get_json_string())










.. _configuration:

=============
Configuration
=============


Command Line Options
====================

Locust is configured mainly through command line arguments.

.. code-block:: console

    $ locust --help

.. literalinclude:: cli-help-output.txt
    :language: console



.. _environment-variables:

Environment Variables
=====================

Options can also be set through environment variables. They are typically the same as the command line argument
but capitalized and prefixed with ``LOCUST_``:

On Linux/macOS:

.. code-block::

    $ LOCUST_LOCUSTFILE=custom_locustfile.py locust

On Windows:

.. code-block::

    > set LOCUST_LOCUSTFILE=custom_locustfile.py
    > locust

.. _configuration-file:

Configuration File
==================

Options can also be set in a configuration file in the
`config or TOML file format <https://github.com/bw2/ConfigArgParse#config-file-syntax>`_.

Locust will look for ``~/.locust.conf``, ``./locust.conf`` and ``./pyproject.toml`` by default.
You can specify an additional file using the ``--config`` flag.

.. code-block:: console

    $ locust --config custom_config.conf

Here's an example:

locust.conf
--------------

.. code-block:: ini

    locustfile = locust_files/my_locust_file.py
    headless = true
    master = true
    expect-workers = 5
    host = https://target-system
    users = 100
    spawn-rate = 10
    run-time = 10m
    tags = [Critical, Normal]

Have a look later in this page for `All available configuration options`_

pyproject.toml
--------------

When using a TOML file, configuration options should be defined within the ``[tool.locust]`` section.

.. code-block:: toml

    [tool.locust]
    locustfile = "locust_files/my_locust_file.py"
    headless = true
    master = true
    expect-workers = 5
    host = "https://target-system"
    users = 100
    spawn-rate = 10
    run-time = "10m"
    tags = ["Critical", "Normal"]

.. note::

    Configuration values are read (and overridden) in the following order:

    .. code-block:: console

       ./pyproject.toml -> ./locust.conf -> (file specified using --config) -> env vars -> cmd args


All available configuration options
===================================

Here's a table of all the available configuration options, and their corresponding Environment and config file keys:

.. include:: config-options.rst

Running without the web UI
==========================

See :ref:`running-without-web-ui`

Using multiple Locustfiles at once
==================================

``-f/--locustfile`` accepts multiple, comma-separated locustfiles.

Example:

With the following file structure:

.. code-block::

    ├── locustfiles/
    │   ├── locustfile1.py
    │   ├── locustfile2.py
    │   └── more_files/
    │       ├── locustfile3.py
    │       ├── _ignoreme.py

.. code-block:: console

    $ locust -f locustfiles/locustfile1.py,locustfiles/locustfile2.py,locustfiles/more_files/locustfile3.py

Locust will use ``locustfile1.py``, ``locustfile2.py`` & ``more_files/locustfile3.py``

Additionally, ``-f/--locustfile`` accepts directories as an option. Locust will recursively
search specified directories for ``*.py`` files, ignoring files that start with "_".

Example:

.. code-block:: console

    $ locust -f locustfiles

Locust will use ``locustfile1.py``, ``locustfile2.py`` & ``more_files/locustfile3.py``



You can also use ``-f/--locustfile`` for web urls. This will download the file and use it as any normal locustfile.

Example:

.. code-block:: console

    $ locust -f https://raw.githubusercontent.com/locustio/locust/master/examples/basic.py


.. _class-picker:

Pick User classes, Shapes and tasks from the UI
===============================================

You can select which Shape class and which User classes to run in the WebUI when running locust with the ``--class-picker`` flag.
No selection uses all the available User classes.

For example, with a file structure like this:

.. code-block::

    ├── src/
    │   ├── some_file.py
    ├── locustfiles/
    │   ├── locustfile1.py
    │   ├── locustfile2.py
    │   └── more_files/
    │       ├── locustfile3.py
    │       ├── _ignoreme.py
    │   └── shape_classes/
    │       ├── DoubleWaveShape.py
    │       ├── StagesShape.py


.. code-block:: console

    $ locust -f locustfiles --class-picker

The Web UI will display:

.. image:: images/userclass_picker_example.png

The class picker additionally allows for disabling individual User tasks, changing the weight or fixed count, and configuring the host.

It is even possible to add custom attributes that you wish to be configurable for each User. Simply add a ``json`` classmethod
to your user:

.. code-block:: python

    class Example(HttpUser):
        some_custom_arg: str = "example"

        @task
        def example_task(self):
            self.client.get(f"/example/{self.some_custom_arg}")

        @classmethod
        def json(cls):
            return {
                "host": cls.host,
                "some_custom_arg": cls.some_custom_arg
            }

.. note::

    The ``json`` classmethod is only used to populate the class picker UI (the gear icon next to each User class).
    It does not automatically set the attribute values on the User class. The default values must be defined as
    class-level attributes (e.g. ``some_custom_arg: str = "example"``). To apply changes made in the UI, click the
    save button for each User class.

Configure Users from command line
=================================

You can update User class attributes from the command line too, using the ``--config-users`` argument:

.. code-block:: console

    $ locust --config-users '{"user_class_name": "Example", "fixed_count": 1, "some_custom_attribute": false}'

To configure multiple users you pass multiple arguments to ``--config-users``, or use a JSON Array. You can also pass a path to a JSON file.

.. code-block:: console

    $ locust --config-users '{"user_class_name": "Example", "fixed_count": 1}' '{"user_class_name": "ExampleTwo", "fixed_count": 2}'
    $ locust --config-users '[{"user_class_name": "Example", "fixed_count": 1}, {"user_class_name": "ExampleTwo", "fixed_count": 2}]'
    $ locust --config-users my_user_config.json

When using this way to configure your users, you can set any attribute.

.. note::

    ``--config-users`` is a somewhat experimental feature and the json format may change even between minor Locust revisions.

Configuring Profiles
====================

Profiles are an advanced feature that allow for grouping and filtering testruns. A profile may be set using the ``--profile`` argument
or by inputting a value in the advanced options from the web ui.

It may be useful to see a list of existing profiles as options in the form. If you have such a list, you may set it in your locustfile:

.. code-block:: python

    from locust import events

    @events.init.add_listener
    def on_locust_init(environment, **kwargs):
        environment.web_ui.template_args["all_profiles"] = ["one", "two", "three"]


.. _custom-load-shape:

Custom load shapes
==================

Sometimes a completely custom shaped load test is required that cannot be achieved by simply setting or changing the user count and spawn rate. For example, you might want to generate a load spike or ramp up and down at custom times. By using a `LoadTestShape` class you have full control over the user count and spawn rate at all times.

Define a class inheriting the LoadTestShape class in your locust file. If this type of class is found then it will be automatically used by Locust.

In this class you define a `tick()` method that returns a tuple with the desired user count and spawn rate (or `None` to stop the test). Locust will call the `tick()` method approximately once per second.

In the class you also have access to the `get_run_time()` method, for checking how long the test has run for.

Example
-------

This shape class will increase user count in blocks of 100 and then stop the load test after 10 minutes:

.. code-block:: python

    class MyCustomShape(LoadTestShape):
        time_limit = 600
        spawn_rate = 20
        
        def tick(self):
            run_time = self.get_run_time()

            if run_time < self.time_limit:
                # User count rounded to nearest hundred.
                user_count = round(run_time, -2)
                return (user_count, self.spawn_rate)

            return None

This functionality is further demonstrated in the `examples on github <https://github.com/locustio/locust/tree/master/examples/custom_shape>`_ including:

- Generating a double wave shape
- Time based stages like K6
- Step load pattern like Visual Studio

One further method may be helpful for your custom load shapes: `get_current_user_count()`, which returns the total number of active users. This method can be used to prevent advancing to subsequent steps until the desired number of users has been reached. This is especially useful if the initialization process for each user is slow or erratic in how long it takes. If this sounds like your use case, see the `example on github <https://github.com/locustio/locust/tree/master/examples/custom_shape/wait_user_count.py>`_.

Note that if you want to defined your own custom base shape, you need to define the `abstract` attribute to `True` to avoid it being picked as Shape when imported:

.. code-block:: python

    class MyBaseShape(LoadTestShape):
        abstract = True
        
        def tick(self):
            # Something reusable but needing inheritance
            return None


Combining Users with different load profiles
--------------------------------------------

If you use the Web UI, you can add the :ref:`---class-picker <class-picker>` parameter to select which shape to use. But it often more flexible to have your User definitions in one file and your LoadTestShape in a separate one. For example, if you a high/low load Shape class defined in low_load.py and high_load.py respectively:

.. code-block:: console

    $ locust -f locustfile.py,low_load.py

    $ locust -f locustfile.py,high_load.py

Restricting which user types to spawn in each tick
--------------------------------------------------

Adding the element ``user_classes`` to the return value gives you more detailed control:

.. code-block:: python

    class StagesShapeWithCustomUsers(LoadTestShape):

        stages = [
            {"duration": 10, "users": 10, "spawn_rate": 10, "user_classes": [UserA]},
            {"duration": 30, "users": 50, "spawn_rate": 10, "user_classes": [UserA, UserB]},
            {"duration": 60, "users": 100, "spawn_rate": 10, "user_classes": [UserB]},
            {"duration": 120, "users": 100, "spawn_rate": 10, "user_classes": [UserA,UserB]},
        ]

        def tick(self):
            run_time = self.get_run_time()

            for stage in self.stages:
                if run_time < stage["duration"]:
                    try:
                        tick_data = (stage["users"], stage["spawn_rate"], stage["user_classes"])
                    except:
                        tick_data = (stage["users"], stage["spawn_rate"])
                    return tick_data

            return None

This shape would create in the first 10 seconds 10 User of ``UserA``. In the next twenty seconds 40 of type ``UserA / UserB`` and this continues until the stages end.

.. _use-common-options:

Reusing common options in custom shapes
---------------------------------------

When using shapes, the *Users*, *Spawn Rate* and *Run Time* options will be hidden from the UI, and if you specify them on command line Locust will log a warning. This is because those options don't directly apply to shapes, and specifying them might be a mistake.

If you really want to combine a shape with these options, set the ``use_common_options`` attribute and access them from ``self.runner.environment.parsed_options``:

.. code-block:: python

    class MyCustomShape(LoadTestShape):
        use_common_options = True
        
        def tick(self):
            run_time = self.get_run_time()
            if run_time < self.runner.environment.parsed_options.run_time:
                # User count rounded to nearest hundred, just like in previous example
                user_count = round(run_time, -2)
                return (user_count, self.runner.environment.parsed_options.spawn_rate)
                
            return None


Save test statistics in CSV format
==================================

When running Locust with the web UI, you can retrieve CSV files under the Download Data tab. 

Or you can run Locust with a flag which will periodically save four CSV files. This is particularly useful
if you plan on running Locust in an automated way with the ``--headless`` flag:

.. code-block:: console

    $ locust -f examples/basic.py --csv example --headless -t10m

The files will be named ``example_stats.csv``, ``example_failures.csv``, ``example_exceptions.csv`` and ``example_stats_history.csv``
(when using ``--csv example``). The first two files will contain the stats and failures for the whole 
test run, with a row for every stats entry (URL endpoint) and an aggregated row. The ``example_stats_history.csv`` 
will get new rows with the *current* (10 seconds sliding window) stats appended during the whole test run. 
By default only the Aggregate row is appended regularly to the history stats, but if Locust is started with 
the ``--csv-full-history`` flag, a row for each stats entry (and the Aggregate) is appended every time 
the stats are written (once every 2 seconds by default).

You can also customize how frequently this is written:

.. code-block:: python

    import locust.stats
    locust.stats.CSV_STATS_INTERVAL_SEC = 5 # default is 1 second

Custom arguments
================

See :ref:`custom-arguments`

Customization of statistics settings
====================================

Default configuration for Locust statistics is set in constants of stats.py file.
It can be tuned to specific requirements by overriding these values.
To do this, import locust.stats module and override required settings:

.. code-block:: python

    import locust.stats
    locust.stats.CONSOLE_STATS_INTERVAL_SEC = 15

It can be done directly in Locust file or extracted to separate file for common usage by all Locust files.

The list of statistics parameters that can be modified is:

+-----------------------------------------+----------------------------------------------------------------------------------+----------------------------------------------------------------------+
| Parameter name                          | Purpose                                                                          | Default value                                                        |
+-----------------------------------------+----------------------------------------------------------------------------------+----------------------------------------------------------------------+
| STATS_NAME_WIDTH                        | Width of column for request name in console output                               | terminal size or 80                                                  |
+-----------------------------------------+----------------------------------------------------------------------------------+----------------------------------------------------------------------+
| STATS_TYPE_WIDTH                        | Width of column for request type in console output                               | 8                                                                    |
+-----------------------------------------+----------------------------------------------------------------------------------+----------------------------------------------------------------------+
| CSV_STATS_INTERVAL_SEC                  | Interval for how frequently the CSV file is written if this option is configured | 1                                                                    |
+-----------------------------------------+----------------------------------------------------------------------------------+----------------------------------------------------------------------+
| CONSOLE_STATS_INTERVAL_SEC              | Interval for how frequently results are written to console / chart UI            | 2                                                                    |
+-----------------------------------------+----------------------------------------------------------------------------------+----------------------------------------------------------------------+
| HISTORY_STATS_INTERVAL_SEC              | Interval for how frequently results are written to history                       | 5                                                                    |
+-----------------------------------------+----------------------------------------------------------------------------------+----------------------------------------------------------------------+
| CURRENT_RESPONSE_TIME_PERCENTILE_WINDOW | Window size/resolution - in seconds - when calculating the current response      | 10                                                                   |
|                                         | time percentile                                                                  |                                                                      |
+-----------------------------------------+----------------------------------------------------------------------------------+----------------------------------------------------------------------+
| PERCENTILES_TO_REPORT                   | List of response time percentiles to be calculated & reported                    | [0.50, 0.66, 0.75, 0.80, 0.90, 0.95, 0.98, 0.99, 0.999, 0.9999, 1.0] |
+-----------------------------------------+----------------------------------------------------------------------------------+----------------------------------------------------------------------+
| PERCENTILES_TO_STATISTICS               | List of response time percentiles in the screen of statistics for UI             | [0.95, 0.99]                                                         |
+-----------------------------------------+----------------------------------------------------------------------------------+----------------------------------------------------------------------+
| PERCENTILES_TO_CHART                    | List of response time percentiles in the screen of chart for UI                  | [0.5, 0.95]                                                          |
+-----------------------------------------+----------------------------------------------------------------------------------+----------------------------------------------------------------------+

.. _customizing-response-time-bucketing:

Customizing response time bucketing
====================================

Response times are grouped into histogram buckets before being stored in the
``response_times`` dict. By default, Locust rounds to approximately 2 significant
digits (e.g. 147 becomes 150, 3432 becomes 3400). This keeps the dict small,
which matters in distributed mode where the dict is serialized from workers to master.

You can replace the bucketing function to change this behaviour:

.. code-block:: python

    import locust.stats
    from math import floor, log10

    def my_bucket_function(response_time: int | float) -> int:
        """Example: bucket to 3 significant figures."""
        if response_time == 0:
            return 0
        return int(round(response_time, -int(floor(log10(abs(response_time)))) + 2))

    locust.stats.bucket_response_time = my_bucket_function

The replacement function receives a single numeric argument (the response time in
milliseconds) and must return a numeric value to use as the dict key. Keep in mind
that more unique keys means more data transferred in distributed mode.

Customization of additional static variables
================












