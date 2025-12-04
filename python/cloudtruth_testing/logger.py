import logging

def setup_logger(
  log_file: str | None = None,
  console_level: int = logging.INFO,
  file_level: int = logging.DEBUG
) -> logging.Logger:
    logger = logging.getLogger("cloudtruth_testing")
    logger.setLevel(logging.DEBUG)  # Set to lowest so handlers control output

    # Prevent duplicate handlers
    if not logger.handlers:
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
