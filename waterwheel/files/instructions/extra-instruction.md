# Extra Test Instruction

## Global Rules
- **URL Rewriting:** Any URL containing `http://localhost` encountered during the test 
  (in page content, emails, or links) MUST be rewritten to use `http://host.docker.internal` 
  before navigating. For example, `http://localhost:8080/confirm-email?token=abc` becomes 
  `http://host.docker.internal:8080/confirm-email?token=abc`. Never navigate to a 
  `localhost` URL directly.