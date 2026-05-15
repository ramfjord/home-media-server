# SMTP

A Postfix relay that accepts mail from anything on the stack and
forwards it to an upstream SMTP provider. Lets services (mainly
Alertmanager, and any *arr that wants to email notifications) emit
mail without each one having to know the upstream provider's
credentials.

## More

- Upstream: <https://github.com/bokysan/docker-postfix>
