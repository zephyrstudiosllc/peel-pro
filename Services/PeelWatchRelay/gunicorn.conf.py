"""Deploy only with an explicitly reviewed real config path and TLS proxy.

The application factory is loaded after fork; never add --preload or workers>1.
This file itself creates no listener, process, data, registration or credential.
"""
import os

bind = "127.0.0.1:8943"
workers = 1
threads = 4
worker_class = "gthread"
preload_app = False
timeout = 60
graceful_timeout = 30
limit_request_line = 4094
limit_request_fields = 32
limit_request_field_size = 8190
accesslog = None
errorlog = "-"
capture_output = False
forwarded_allow_ips = "127.0.0.1"
secure_scheme_headers = {"X-FORWARDED-PROTO": "https"}

# An exact absolute private configuration path must be supplied by the operator.
# Gunicorn factory command is documented separately; never read a public config
# or use its ambient import path as credential/account authority.
