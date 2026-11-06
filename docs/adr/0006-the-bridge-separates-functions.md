# The bridge separates an accessory's Functions itself, when a person asks

The Home app will not group an accessory that has others attached: a light with a sensor, or anything shown with
accessories inside it. Plugins publish a device's Functions on one accessory, and only some offer more than one
accessory per device. So with Groups following Apple Home (ADR 0005), many accessories could never join one.

Separate Functions is now a Core Accessory Setting, off by default, and the bridge itself applies it for every plugin.
Each Function becomes an accessory of its own, keyed `<deviceID>:<more>` as ADR 0003 allows, with its own Name
(the device's plus the Function), room (the device's to start with), Hidden, Not in Home and Group. The main Function
stays on the device's own accessory, which keeps its aid, so its scenes and automations survive. Battery and identity
go with every accessory made from the device. A plugin only declares the Functions that must stay together, such as a
camera and the motion sensor its recordings need, a doorbell, a television and its inputs, or a lock and its lock
management.

## Considered Options

- **Each plugin offers splitting for the devices it chooses:** most plugins would never do it, and Groups would stay
  out of reach for their accessories.

## Consequences

- Separating, and joining back, changes Apple Home. The separated Functions leave the existing tile, and the scenes and
  automations that used them there need redoing. A warning says so first. Joining back also lists the Groups that may
  dissolve.
- Homeswift offers to separate an accessory when grouping it is refused, and in its settings.
- Wingman's mirrors are Apple Home's own accessories, so they are never separated.
