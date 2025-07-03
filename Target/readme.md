
# Audio Stream Setup

## Required Packages

* **GStreamer** and relevant **plug-ins**
* **CamillaDSP**
  Installation instructions: [CamillaDSP GitHub Repository](https://github.com/HEnquist/camilladsp)
* **simple-whip-client**
  Customized to reference environment variables for:

  * WHIP endpoint
  * Bearer token
  * GStreamer pipelines

---

## Files and Descriptions

### `audiostream.service`

* Waits for internet connectivity.
* Launches `start_camilladsp-whip.sh`.

### `start_camilladsp-whip.sh`

* Creates a named pipe (if needed).
* Starts **CamillaDSP**.
* Starts **whip-client**.

### `camilladsp`

* Reads audio input from HiFiBerry.
* Writes output to the named pipe.

### `whip-client`

* Connects to WHIP server.
* Launches **GStreamer** for streaming.

---

## Raspberry Pi Configuration

Add the following line to `/boot/firmware/config.txt` for **HiFiBerry DAC2 ADC Pro** support:

```txt
dtoverlay=hifiberry-dacplusadcpro
```

---

## CamillaDSP Configuration

* Pipeline and filters:
  `/home/audiostream/camilladsp.yml`

* Gain settings:
  `/home/audiostream/state.yml`

---

## Installing the `audiostream` Service

Create symbolic links to enable the service:

```bash
sudo ln -s /home/audiostream/audiostream.service /etc/systemd/system
sudo ln -s /etc/systemd/system/audiostream.service /etc/systemd/system/multi-user.target.wants
```

---

## Monitoring Execution

Use `journalctl` to follow service logs:

```bash
sudo journalctl -f
```


