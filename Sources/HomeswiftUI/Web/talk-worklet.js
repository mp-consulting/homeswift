// The microphone button of a camera's live view (camera.js): the microphone, resampled to the camera's rate as signed
// 16-bit little-endian mono, posted to the page every `chunk` milliseconds. Runs on the audio thread.
class HomeswiftTalk extends AudioWorkletProcessor {
  constructor(options) {
    super();
    const { rate, chunk } = options.processorOptions;
    // Input samples per output sample: 3 from 48 kHz to 16 kHz.
    this.step = sampleRate / rate;
    this.position = 0;
    this.sum = 0;
    this.count = 0;
    this.out = new DataView(new ArrayBuffer(Math.round(rate * chunk / 1000) * 2));
    this.length = 0;
  }

  process(inputs) {
    const input = inputs[0]?.[0];
    if (!input) return true;
    for (let i = 0; i < input.length; i++) {
      // Each output sample is the mean of the input it spans: a box filter, enough for speech.
      this.sum += input[i];
      this.count++;
      this.position++;
      if (this.position < this.step) continue;
      this.position -= this.step;
      const value = Math.max(-1, Math.min(1, this.sum / this.count));
      this.sum = 0;
      this.count = 0;
      this.out.setInt16(this.length, Math.round(value * 32767), true);
      this.length += 2;
      if (this.length === this.out.byteLength) {
        // A transferred buffer is empty here afterwards: its size first.
        const size = this.out.byteLength;
        this.port.postMessage(this.out.buffer, [this.out.buffer]);
        this.out = new DataView(new ArrayBuffer(size));
        this.length = 0;
      }
    }
    return true;
  }
}

registerProcessor("homeswift-talk", HomeswiftTalk);
