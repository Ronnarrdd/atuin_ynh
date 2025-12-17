## Registration is disabled by default
This package installs Atuin with:
- `open_registration = false`
That means new users **cannot** register until you enable registration manually.

### Enable registration (temporarily)
```bash
sudo sed -i 's/^open_registration = .*/open_registration = true/' /home/yunohost.app/atuin/server.toml
sudo systemctl restart atuin
```
Now users can register using the Atuin client.

### Disable registration
```bash
sudo sed -i 's/^open_registration = .*/open_registration = false/' /home/yunohost.app/atuin/server.toml
sudo systemctl restart atuin
```
## Troubleshooting
```bash
sudo journalctl -u atuin -f -l
```
