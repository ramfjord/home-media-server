FROM python:3.13-alpine

RUN pip install --no-cache-dir 'httpx>=0.27,<1.0' 'pyyaml>=6,<7'

COPY configure.py /usr/local/bin/api-configure
RUN chmod +x /usr/local/bin/api-configure

ENTRYPOINT ["api-configure"]
