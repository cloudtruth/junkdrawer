import logging

def setup_logger(log_file=None, console_level=logging.INFO, file_level=logging.DEBUG):
    logger = logging.getLogger("cloudtruth_testing")
    logger.setLevel(logging.DEBUG)  # Set to lowest so handlers control output

    formatter = logging.Formatter('%(asctime)s %(levelname)s: %(message)s')

    # Console handler
    ch = logging.StreamHandler()
    ch.setLevel(console_level)
    ch.setFormatter(formatter)
    logger.addHandler(ch)

    # File handler (optional)
    if log_file:
        fh = logging.FileHandler(log_file)
        fh.setLevel(file_level)
        fh.setFormatter(formatter)
        logger.addHandler(fh)

    return logger
