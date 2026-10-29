"""cPanel WSGI entry. Missing/disabled configuration responds 503."""
from peel_accounts import create_app

application = create_app()
