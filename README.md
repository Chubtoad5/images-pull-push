# images-pull-push
Script to pull, push, and save container images dynamically

## Getting started
```
git clone https://github.com/Chubtoad5/images-pull-push.git

```

##  Usage
```
Usage: sudo images_pull_push.sh -f <path_to_images_file> [<save>] [<push> <registry:port> [<username> <password>]]

This script must be run with root privileges.

Parameters:
  -f <path_to_images_file>   : Path to the file containing a list of container images and tags (one per line).
                               Alternatively, this can be a .tar.gz file created by this script for air-gapped mode.
  <save>                     : Optional. If specified, saves the images to a .tar.gz file.
  <push>                     : Optional. Pushes the images to a specified registry after saving.
  <registry:port>            : Required when <push> is specified. The target registry URL and port.
  <username>                 : Optional. The username for the registry.
  <password>                 : Optional. Required when <username> is specified. The password for the registry.
```

## Examples
### Pull and save images:
```
sudo ./images_pull_push.sh -f my_images.txt save
```

### Pull, save, and push to a registry:
```
sudo ./images_pull_push.sh -f my_images.txt save push my-registry.com:5000 <username> <password>
```

### Load images from a local file and push (air-gapped):
```
sudo ./images_pull_push.sh -f container_images_...tar.gz push my-registry.com:5000 <username> <password>
```

