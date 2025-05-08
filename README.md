# tf-aws-module-template

<!-- BEGIN_TF_DOCS -->

Template for AWS Terraform Modules

## Overview

This repository serves as a template for AWS Terraform modules, with built-in GitHub Actions for automatic publishing to S3 and documentation generation.

## Publishing to S3 with GitHub Actions

This repository includes a GitHub Actions workflow that automatically packages and publishes the Terraform module to an S3 bucket when a new release is created or manually triggered.

### How the Workflow Works

The workflow (`publish-version.yml`) performs the following steps:

1. Checks out the code
2. Configures AWS credentials using OIDC authentication
3. Determines the version to publish
4. Packages the module into a zip file
5. Uploads the zip file to an S3 bucket

### Required GitHub Secrets

You must set up the following GitHub Action secrets in your repository:

- `AWS_ACCOUNT_ID`: The AWS account ID where the S3 bucket and IAM role exist
- `S3_BUCKET_NAME`: The name of the S3 bucket where modules will be published

### How to Set Up GitHub Secrets

1. Navigate to your repository on GitHub
2. Click on **Settings** > **Secrets and variables** > **Actions**
3. Click on **New repository secret**
4. Add each required secret with its appropriate value

### GitHub OIDC Configuration

This workflow uses OIDC for authentication. You must set up an IAM role in AWS:

1. Create an IAM role named `AWS-TF-GITHUB-ROLE` with the following trust policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:YourOrg/YourRepo:*"
        }
      }
    }
  ]
}
```

2. Attach a policy to this role that allows writing to the S3 bucket

### Manually Triggering the Workflow

You can manually trigger the workflow:

1. Go to the **Actions** tab in your repository
2. Select the **Publish Terraform Module to S3** workflow
3. Click on **Run workflow**
4. Optionally specify a version or region

## Terraform Documentation Automation

This repository is set up to automatically generate documentation using `terraform-docs`.

### How to Use Terraform-docs

1. Install terraform-docs:

```bash
brew install terraform-docs    # macOS

# For Windows:
# Option 1: Using Chocolatey
choco install terraform-docs

# Option 2: Using Scoop
scoop install terraform-docs

# Option 3: Manual installation
# Download the latest Windows binary from https://github.com/terraform-docs/terraform-docs/releases
# Extract it and add to your PATH
```

2. Create a `.config/.terraform-docs.yml` configuration file with your preferred settings
3. Run the following command to update the README:

```bash
terraform-docs --config .config/.terraform-docs.yml .
```

4. Documentation will be inserted between the `<!-- BEGIN_TF_DOCS -->` and `<!-- END_TF_DOCS -->` markers in this README (It will replace this existing content in the repo template).

### GitHub Action for Documentation

You can set up a GitHub Action to automatically update documentation on pull requests by adding a workflow file.

## Getting Started

To use this template:

1. Click the "Use this template" button on GitHub
2. Set up required GitHub secrets
3. Update your module code
4. Create a new release to automatically publish to S3

<!-- END_TF_DOCS -->
