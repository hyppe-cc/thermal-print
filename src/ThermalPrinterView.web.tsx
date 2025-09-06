import * as React from 'react';

import { ThermalPrinterViewProps } from './ThermalPrinter.types';

export default function ThermalPrinterView(props: ThermalPrinterViewProps) {
  return (
    <div>
      <iframe
        style={{ flex: 1 }}
        src={props.url}
        onLoad={() => props.onLoad({ nativeEvent: { url: props.url } })}
      />
    </div>
  );
}
