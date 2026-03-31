You are implementing a feature spec. Follow this exact sequence:

BEFORE WRITING CODE:

1. Read the full spec below
2. List every file you will create or modify — get my approval
3. List every database change — get my approval
4. Flag any conflicts with existing code
5. DO NOT proceed until I confirm

WHILE IMPLEMENTING:

- Follow the spec exactly. Do not add, remove, or change scope.
- Make surgical changes. Do not refactor adjacent code.
- If something in the spec is ambiguous, stop and ask.

AFTER IMPLEMENTING:

1. npx tsc --noEmit — fix ALL type errors
2. npm run build — must pass
3. List every file changed with a one-line summary
4. Provide test steps for: operator_admin, field_staff, warehouse

SPEC:
$ARGUMENTS
