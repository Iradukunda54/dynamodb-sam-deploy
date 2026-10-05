# Deploy DynamoDB Table with AWS SAM

This repo provisions an Amazon DynamoDB table with AWS SAM. The table has a primary key, two named non-key attributes and two Global Secondary Indexes. Two separate GitHub Actions pipelines deploy it to a **dev** and a **prod** environment, and each environment has its own S3 artifact bucket.

## What gets deployed

| Setting | Value |
|---|---|
| Table name | `books-catalog-<env>-books` (`<env>` = `dev` or `prod`) |
| Billing mode | `PAY_PER_REQUEST` (On-Demand) |
| Table class | `STANDARD_INFREQUENT_ACCESS` (not the default `STANDARD`) |
| Primary key | `BookId` (String, partition key; no sort key) |
| Named non-key attributes | `Author` (String), `Genre` (String) |
| GSI 1 | `AuthorIndex`: partition key `Author`, projection `ALL` |
| GSI 2 | `GenreIndex`: partition key `Genre`, projection `ALL` |
| Encryption | Server-side encryption (AWS-managed KMS key) |
| Prod only | Point-in-time recovery and deletion protection |

Items may also hold free-form attributes such as `Title` and `PublishedYear`. DynamoDB is schemaless, so a template can only declare attributes that are used in a table or index key (`AttributeDefinitions`). This is why `BookId`, `Author` and `Genre` are the only ones declared in [template.yaml](template.yaml).

## Architecture

```
            push to "develop"                         push to "main"
                   |                                        |
     .github/workflows/deploy-dev.yml        .github/workflows/deploy-prod.yml
                   |  GitHub OIDC (no stored keys)          |  GitHub OIDC
                   v                                        v
   dev PipelineExecutionRole                  prod PipelineExecutionRole
                   |  sam deploy --config-env dev           |  sam deploy --config-env prod
                   v                                        v
   dev artifacts S3 bucket                    prod artifacts S3 bucket
                   |                                        |
   dev CloudFormationExecutionRole            prod CloudFormationExecutionRole
                   v                                        v
   stack: books-catalog-dev                   stack: books-catalog-prod
     └─ DynamoDB books-catalog-dev-books        └─ DynamoDB books-catalog-prod-books
          ├─ AuthorIndex                             ├─ AuthorIndex
          └─ GenreIndex                              └─ GenreIndex
```

**AWS services:** Amazon DynamoDB, AWS CloudFormation (through AWS SAM), Amazon S3 (artifact buckets), AWS IAM (GitHub OIDC provider and roles).

## Repository layout

```
template.yaml                     SAM template (the DynamoDB table)
samconfig.toml                    dev and prod deploy settings (stack name, parameters)
.github/workflows/deploy-dev.yml  dev pipeline: develop branch -> dev stack only
.github/workflows/deploy-prod.yml prod pipeline: main branch  -> prod stack only
scripts/verify-table.sh           optional CLI check (put / get / query GSIs / update / delete)
```

## Prerequisites

- AWS CLI v2 and AWS SAM CLI, configured with an admin-capable profile (needed only for the one-time bootstrap)
- A GitHub repository for this code, with two branches: `develop` and `main`

## One-time setup: SAM Pipeline bootstrap (per environment)

`sam pipeline bootstrap` creates a dedicated set of pipeline resources for each stage:
- an S3 artifact bucket
- a pipeline execution role, which GitHub Actions assumes through OIDC
- a CloudFormation execution role

Running it once per stage is what gives each environment its own artifact bucket.

Use the exact GitHub owner login (case-sensitive, it is matched in the IAM trust policy). For this repo that is `Iradukunda54`:

```bash
# dev stage: trusted only for the "develop" branch
sam pipeline bootstrap --no-interactive --no-confirm-changeset \
  --stage dev --region eu-west-1 \
  --permissions-provider oidc --oidc-provider github-actions \
  --oidc-provider-url https://token.actions.githubusercontent.com \
  --oidc-client-id sts.amazonaws.com \
  --github-org Iradukunda54 --github-repo dynamodb-sam-deploy \
  --deployment-branch develop

# prod stage: trusted only for the "main" branch
sam pipeline bootstrap --no-interactive --no-confirm-changeset \
  --stage prod --region eu-west-1 \
  --permissions-provider oidc --oidc-provider github-actions \
  --oidc-provider-url https://token.actions.githubusercontent.com \
  --oidc-client-id sts.amazonaws.com \
  --github-org Iradukunda54 --github-repo dynamodb-sam-deploy \
  --deployment-branch main
```

> If the account already has the GitHub OIDC provider (`token.actions.githubusercontent.com`), the second bootstrap reuses it.

Each run creates a stack named `aws-sam-cli-managed-<stage>-pipeline-resources`. To read the values you need, run:

```bash
aws cloudformation describe-stacks --stack-name aws-sam-cli-managed-dev-pipeline-resources \
  --query "Stacks[0].Outputs" --output table
aws cloudformation describe-stacks --stack-name aws-sam-cli-managed-prod-pipeline-resources \
  --query "Stacks[0].Outputs" --output table
```

### GitHub repository variables

Go to **Settings → Secrets and variables → Actions → Variables** and add the following. These are ARNs and bucket names, not secrets. No AWS access keys are stored in GitHub.

| Variable | Value |
|---|---|
| `AWS_REGION` | `eu-west-1` |
| `DEV_PIPELINE_EXECUTION_ROLE` | `PipelineExecutionRole` output of the dev bootstrap stack |
| `DEV_CLOUDFORMATION_EXECUTION_ROLE` | `CloudFormationExecutionRole` output of the dev bootstrap stack |
| `DEV_ARTIFACTS_BUCKET` | `ArtifactsBucket` output of the dev bootstrap stack (bucket **name**, not ARN) |
| `PROD_PIPELINE_EXECUTION_ROLE` | `PipelineExecutionRole` output of the prod bootstrap stack |
| `PROD_CLOUDFORMATION_EXECUTION_ROLE` | `CloudFormationExecutionRole` output of the prod bootstrap stack |
| `PROD_ARTIFACTS_BUCKET` | `ArtifactsBucket` output of the prod bootstrap stack (bucket **name**, not ARN) |

### First-deployment order

1. Run the two bootstrap commands above.
2. Create the GitHub repo and set the repository variables.
3. Push the `develop` branch. The dev pipeline deploys `books-catalog-dev`. Check it in the console.
4. Push or merge into `main`. The prod pipeline deploys `books-catalog-prod`.

Pushing `main` before steps 1–2 causes a failed prod run. Pushing `main` before `develop` deploys prod before dev.

## Deployment (CI/CD)

`sam pipeline init` normally generates one workflow that deploys every stage. This repo replaces it with **two independent pipelines**:

| Workflow | Trigger | Deploys | Uses |
|---|---|---|---|
| [deploy-dev.yml](.github/workflows/deploy-dev.yml) | push to `develop`, or manual run | stack `books-catalog-dev` only | dev role and dev artifact bucket |
| [deploy-prod.yml](.github/workflows/deploy-prod.yml) | push to `main`, or manual run | stack `books-catalog-prod` only | prod role and prod artifact bucket |

Each pipeline runs these steps:
1. `sam validate --lint`
2. `sam build`
3. Assume its own pipeline execution role through OIDC
4. `sam deploy --config-env <env>`, with that environment's own artifact bucket and CloudFormation execution role

Typical flow: merge feature work into `develop` to deploy to dev and test there. Then merge `develop` into `main` to deploy to prod.

> The deploy jobs don't use GitHub `environment:` on purpose. With an environment set, the OIDC token's `sub` claim becomes `repo:<owner>/<repo>:environment:<name>`. The bootstrap roles only trust `repo:<owner>/<repo>:ref:refs/heads/<branch>`.

### Manual deploy from a workstation (optional)

```bash
sam validate --lint
sam build
sam deploy --config-env dev  --s3-bucket <dev-artifacts-bucket>
sam deploy --config-env prod --s3-bucket <prod-artifacts-bucket>
```

## Verification in the AWS Console

1. Open **DynamoDB → Tables → `books-catalog-dev-books`**. Check these:
   - **Overview → Capacity mode:** On-demand
   - **Table class:** DynamoDB Standard-IA
   - **Indexes** tab: `AuthorIndex` and `GenreIndex`
2. **Insert:** go to **Explore table items → Create item**, switch to JSON view, turn off "View DynamoDB JSON" and paste:
   ```json
   { "BookId": "b-001", "Title": "Things Fall Apart", "Author": "Chinua Achebe", "Genre": "Fiction", "PublishedYear": 1958 }
   ```
   Add a few more items, for example:
   ```json
   { "BookId": "b-002", "Title": "Arrow of God", "Author": "Chinua Achebe", "Genre": "Fiction", "PublishedYear": 1964 }
   { "BookId": "b-003", "Title": "A Brief History of Time", "Author": "Stephen Hawking", "Genre": "Science", "PublishedYear": 1988 }
   ```
3. **Read by key:** choose **Query** with table `books-catalog-dev-books` and `BookId = b-001`.
4. **Query a GSI:** choose **Query**, select index `AuthorIndex`, set `Author = Chinua Achebe` → 2 items. Then select `GenreIndex` and set `Genre = Science` → 1 item.
5. **Update:** open an item, change `Genre`, and save. Query `GenreIndex` again to see the change.
6. **Delete:** select an item, then choose **Actions → Delete items**.

You can run the same checks from the CLI:

```bash
./scripts/verify-table.sh dev eu-west-1
```

## Expected result

- CloudFormation shows two stacks, `books-catalog-dev` and `books-catalog-prod`, both deployed by GitHub Actions.
- Each stack owns one On-Demand, Standard-IA DynamoDB table with the `AuthorIndex` and `GenreIndex` GSIs.
- Dev and prod artifacts sit in separate S3 buckets (`aws-sam-cli-managed-dev-…` and `aws-sam-cli-managed-prod-…`).
- You can insert, query (by key and through both GSIs), update and delete items from the console.

## Clean up

```bash
sam delete --stack-name books-catalog-dev --region eu-west-1
# prod has deletion protection; turn it off on the table first, then:
sam delete --stack-name books-catalog-prod --region eu-west-1
```
Empty and delete the bootstrap stacks (`aws-sam-cli-managed-<stage>-pipeline-resources`) when you no longer need them.
