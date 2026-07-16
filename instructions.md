# brew-thermostat

This file contains instructions about the project I want to build to monitor and control my fermentation vessel's temperature.

## Background

- I brew kombucha in the UK. At the moment the ambient temperature is hot (about 25C) and so is ideal for kombucha fermentation.
- Generally, outside of this heatwave, the UK temperature is too low, and too variable (you can see on the web the requirements, but ideal is about 24C, 20C is too low, and 35C is hot enough to kill the SCOBY).
- I have bought a simple "Bew Belt" (https://www.amazon.co.uk/dp/B07FKPP1QR) that can be used to warm the fermentation vessel up.
- This brew belt is very simple: 25W output, no thermostat. It is designed to be constantly fiddled with in order to keep temperature in the ideal range.
- I chose the simple bew belt for 2 reasons:
  - I hate spending money.
  - I know a reasonable amount about micro-electronics and will enjoy coblling something together myself.
- I already have a DS18B20-based temperature sensor (available on http://192.168.0.64 if you need to look).
- I have a spare smart plug (https://www.mylocalbytes.com/products/smart-plug-pm) that I can use to turn the heater on and off.
- Both the sensor and plug run Tasmota.
- I have HomeAssistant (HA) running on a Pi, 192.168.0.2. This integrates with an MQTT server (on the same IP).

## Requirements

- I want the system to **fail safe**. That is, turn off the heater if anything goes wrong. In this context that means the plug should turn itself off if it has not received any temperature measurements for 10 mins. This should happen if the WiFi goes down, meaning it must be the plug that applies that fail-safe; it can't be done from the HomeAssistant server. I believe Tasmota has something similar to a Watchdog timer.
- I would prefer the sensor and plug to talk together natively, rather than relying on sensor -> MQTT -> HA -> rule firing -> MQTT -> plug. I believe this is possible in Tasmota, but I could be wrong.
- I want the sensor and plug to be integrated with HomeAssistant, or at least expose Prometheus metrics.

## Notes
- This project might not involve generating much code, but instead it will be you telling me "type _this_ into the Tasmota console". For that reason, creating good documentation is a prime requirement; I might need to repeat this again in a few months. Documentation includes a CLAUDE.md and a README.md
- I've done a `git init` but nothing else. We'll need to create an origin ( user `paulcager` on github.com)

