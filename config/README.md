# Neon configuration

`neon.example.json` is a non-secret template for
[`scripts/neon_setup.py`](../scripts/neon_setup.py). Copy it to the ignored
`config/neon.json`, then replace the project-specific values before running
`validate` or `setup`.

## Selecting an existing project

In the Neon Console, open the project you want Agent Gateway to use. Find the
project's **Project ID** and **Region** in its project details/settings. Copy
those values into `project_id` and `region_id`. Use the region identifier
shown for that project (for example, `aws-eu-west-2`); do not choose a different
region. The helper checks that the configured region matches the project.

For an existing project, keep `mode` as `"existing"` and `project_name` as an
empty string. You can usually leave `branch_id` empty: the helper selects the
project's default branch. To use a non-default branch, copy that branch's ID
from the Neon Console and set `branch_id`; it must belong to the selected
project.

`database_name` and `application_role` are the PostgreSQL database and role
that Agent Gateway will use on the selected branch. Choose lowercase names
using letters, numbers, and underscores. The helper creates the role and
database if they do not exist. If the named database already exists, it must
already be owned by the configured application role; the helper will not change
its owner.

## Creating a dedicated project instead

To let the helper create a new Neon project, set `mode` to `"create"`, provide
a descriptive `project_name`, and leave `project_id` and `branch_id` empty.
Choose the Neon `region_id` where the project should be created. The helper
uses the project name as the exact confirmation text for the create command.

## Run the helper

Set `NEON_API_KEY` using your approved secure method, then validate the
non-secret configuration:

```sh
python3 -B scripts/neon_setup.py --config config/neon.json validate
```

For an existing project, use its exact configured ID to confirm setup:

```sh
python3 -B scripts/neon_setup.py --config config/neon.json setup \
  --confirm-existing-project "YOUR_NEON_PROJECT_ID"
```

For a new project, confirm using its configured name:

```sh
python3 -B scripts/neon_setup.py --config config/neon.json setup \
  --confirm-create "YOUR_CONFIGURED_PROJECT_NAME"
```

The helper writes generated connection credentials to the ignored,
owner-only `config/neon-credentials.json`. Do not share or commit that file,
the Neon API key, or any database connection string.
