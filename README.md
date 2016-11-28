# GTFO TFS!

TFVC to Git Migration tool. Made for unattended migration using a unix system, i.e. it doesn't need Windows. Please follow the complete migration guide or you *will* run into issues!

## Migration Guide

### Step 1: Setup

gtfotfs is a Bash 4 script and needs

- `tf` (Team Explorer Everywhere, MS's Java client for TFS)
  - Download from MS [here](https://github.com/Microsoft/team-explorer-everywhere/releases)
  - Run `tf eula`  and accept the EULA
  - `export TF_AUTO_SAVE_CREDENTIALS=1`
  - Run *any* `tf` command and supply account credentials using the `-login` option.
  - From now on, `tf` uses the saved credentials. gtfotfs assumes `tf` uses saved credentials.
- `jq` (JSON query tool)
  - Install via your package manager, e.g. `apt install jq`.
- `xml2json`
  - Install via `pip`.
- `git`


### Step 2: Preparing the TFVC Repository

gtfotfs expects a single source path in the form of `$/contoso/superapp/master`. Make sure that whatever path you supply (down to what TFS dares to call *branch*) contains everything you need to build your project.

### Step 3: Choosing What to Keep

- Identify the numeric ID of the changeset you want the migration to start at, e.g. `1337`. Any history before that will be lost.
- Optionally, create a `.gitignore` file. This can be passed to gtfotfs and will be applied to all commits, dropping files in the TFVC repository which do not match the filter. This is a good way to get rid of some historical mess.

In general, aim to make the resulting repository as clean as possible. Only code, or other plain text documents should live in a git repo. Exclude build artifacts, binaries, PDFs, compressed archives etc.

### Step 4: Creating a New Remote

Set up an empty git repository somewhere and copy the remote origin path. gtfotfs assumes the machine which it is running on has push access to that remote. If not, the script will fail in the final stage, but a local copy of the result repo remains for you to debug.

### Step 5: Prepare Name Mapping

Authors in TFS are saved according to your authentication scheme. These need to be mapped to proper git author tags. See the help output for gtfotfs to learn how to set up a mapping file.

### Step 6: Migrate!

Run `gtfotfs` once without arguments to view the manual. Additionally, here's a complete example of a simple migration:

```bash
./gtfotfs \
  --collection "https://tfs.contoso.com/tfs/ProjectCollection" \
  --source "$/contoso/superapp/master" \
  --target /tmp/repo \
  --names `pwd`/name-map.json \
  --remote "Contoso@vs-ssh.visualstudio.com:v3/Contoso/ConTeam/SuperApp"  \
  --history 33444 \
  --ignore `pwd`/my-ignore
```

Optionally, you can also supply `-k/--keep`, which will assume the target directory already contains a git repo and simply continue the migration on top of it. In plain english, the above command will recreate the repository at `$/contoso/superapp/master` and it's history, starting from the changeset ID `33444` and stopping at the tip. It will map owners found in the TFVC changesets to proper owner tags in the git commits according to your name mapping file `name-map.json`. The result repo is being built in `/tmp/repo` and an external `.gitignore` file is applied, sourced from `my-ignore`.

Prepare to make some tea, because this will take quite a while. In a test run, a migration of 3500 changesets across a repo with about 800 MB worth of content took about 10 hours to complete. Original commit dates will of course be preserved.

At the end of this run, before a push is done, the repository is optimized locally.

### Step 7: Integrate

If you have any other TFVC repositories you'd like to migrate, launch a separate migration run with another target. In our test case, there was a separate repo, already in git, which needed to be merged into the main result repo, preserving the history of everything. This can easily be done using git:

```bash
cd /tmp/repo # main repo
git remote add extra /tmp/repo-extra # other source repo
git fetch extra --tags

# Merge or rebase, your choice
git merge --allow-unrelated-histories extra/master # or any other target branch

git remote remove extra

# If neccessary, you can restructure the repo using
git mv src/ dst/
```

## Contributing

- Follow the style of the exisiting code, otherwise read the [shell style guide](https://google.github.io/styleguide/shell.xml)
- Error check everything
- Use `shellcheck gtfotfs` to check syntax errors and code smells
- Avoid adding other dependencies if possible