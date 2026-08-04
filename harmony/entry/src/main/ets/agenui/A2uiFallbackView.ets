import { A2uiComponentDef } from '@loop/agent-core';

interface DeviceRowInfo {
  deviceId: string;
  deviceName: string;
}

@Component
export struct A2uiFallbackView {
  @Prop components: A2uiComponentDef[] = [];
  @Prop bindingDevices: string[] = [];
  @Prop boundDevices: string[] = [];
  onDeviceSelect: (deviceId: string, deviceName: string) => void = (_id: string, _name: string) => {};

  private contains(arr: string[], value: string): boolean {
    for (let index = 0; index < arr.length; index++) {
      if (arr[index] === value) {
        return true;
      }
    }
    return false;
  }

  private rowBackgroundColor(deviceId: string): ResourceColor {
    if (this.contains(this.boundDevices, deviceId)) {
      return '#E8F5E9'; // 绑定成功：浅绿
    }
    if (this.contains(this.bindingDevices, deviceId)) {
      return '#FFF3E0'; // 选中/绑定中：浅橘黄
    }
    return $r('app.color.input_stroke'); // 未绑定：灰
  }

  private findComponent(id: string): A2uiComponentDef | null {
    for (const component of this.components) {
      if (component.id === id) {
        return component;
      }
    }
    return null;
  }

  // 从一个 Row 的 children 里提取设备信息：variant=body 是设备名，variant=caption 是 deviceId。
  private deviceInfoForRow(rowId: string): DeviceRowInfo | null {
    const row = this.findComponent(rowId);
    if (row === null || row.children === undefined) {
      return null;
    }
    let deviceId = '';
    let deviceName = '';
    for (let index = 0; index < row.children.length; index++) {
      const child = this.findComponent(row.children[index]);
      if (child === null) {
        continue;
      }
      if (child.variant === 'caption' && child.text !== undefined) {
        deviceId = child.text;
      } else if (child.variant === 'body' && child.text !== undefined) {
        deviceName = child.text;
      }
    }
    if (deviceId.length === 0 && deviceName.length === 0) {
      return null;
    }
    const info: DeviceRowInfo = { deviceId: deviceId, deviceName: deviceName };
    return info;
  }

  private textFontSize(variant: string | undefined): number {
    if (variant === 'h1') {
      return 28;
    }
    if (variant === 'h2') {
      return 24;
    }
    if (variant === 'h3') {
      return 20;
    }
    if (variant === 'h4') {
      return 18;
    }
    if (variant === 'h5') {
      return 16;
    }
    if (variant === 'caption') {
      return 12;
    }
    return 16;
  }

  private textOpacity(variant: string | undefined): number {
    if (variant === 'caption') {
      return 0.65;
    }
    return 1;
  }

  private buttonLabel(component: A2uiComponentDef): string {
    if (component.child !== undefined) {
      const child = this.findComponent(component.child);
      if (child !== null && child.text !== undefined) {
        return child.text;
      }
    }
    return 'Button';
  }

  build() {
    Column() {
      if (this.components.length === 0) {
        Text('Generated UI will appear here.')
          .fontSize(14)
          .fontColor('#666666')
      } else if (this.findComponent('root') !== null) {
        this.renderNode('root')
      } else {
        Text('No root component in A2UI payload.')
          .fontSize(14)
          .fontColor('#B3261E')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  renderNode(nodeId: string) {
    if (this.findComponent(nodeId)?.component === 'Text') {
      this.renderText(nodeId)
    } else if (this.findComponent(nodeId)?.component === 'Column') {
      this.renderColumn(nodeId)
    } else if (this.findComponent(nodeId)?.component === 'Row') {
      this.renderRow(nodeId)
    } else if (this.findComponent(nodeId)?.component === 'Card') {
      this.renderCard(nodeId)
    } else if (this.findComponent(nodeId)?.component === 'Button') {
      this.renderButton(nodeId)
    } else if (this.findComponent(nodeId)?.component === 'Divider') {
      this.renderDivider()
    } else {
      Text(`Unsupported: ${this.findComponent(nodeId)?.component ?? nodeId}`)
        .fontSize(12)
        .fontColor('#999999')
    }
  }

  @Builder
  renderText(nodeId: string) {
    Text(this.findComponent(nodeId)?.text ?? '')
      .fontSize(this.textFontSize(this.findComponent(nodeId)?.variant))
      .fontColor($r('app.color.text_primary'))
      .opacity(this.textOpacity(this.findComponent(nodeId)?.variant))
      .width('100%')
      .margin({ bottom: 6 })
  }

  @Builder
  renderColumn(nodeId: string) {
    Column() {
      ForEach(this.findComponent(nodeId)?.children ?? [], (childId: string) => {
        this.renderNode(childId)
      }, (childId: string) => childId)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  renderRow(nodeId: string) {
    Row() {
      ForEach(this.findComponent(nodeId)?.children ?? [], (childId: string) => {
        this.renderNode(childId)
      }, (childId: string) => childId)
    }
    .width('100%')
    .padding(this.deviceInfoForRow(nodeId) !== null ? { top: 8, bottom: 8 } : { top: 0, bottom: 0 })
    .borderRadius(8)
    .backgroundColor(this.rowBackgroundColorForNode(nodeId))
    .onClick(() => {
      const info = this.deviceInfoForRow(nodeId);
      if (info !== null) {
        this.onDeviceSelect(info.deviceId, info.deviceName);
      }
    })
  }

  private rowBackgroundColorForNode(nodeId: string): ResourceColor {
    const info = this.deviceInfoForRow(nodeId);
    if (info === null) {
      return Color.Transparent;
    }
    return this.rowBackgroundColor(info.deviceId);
  }

  @Builder
  renderCard(nodeId: string) {
    Column() {
      if (this.findComponent(nodeId)?.child !== undefined) {
        this.renderNode(this.findComponent(nodeId)?.child ?? '')
      }
      ForEach(this.findComponent(nodeId)?.children ?? [], (childId: string) => {
        this.renderNode(childId)
      }, (childId: string) => childId)
    }
    .width('100%')
    .padding(16)
    .borderRadius(12)
    .backgroundColor(Color.White)
    .border({ width: 1, color: $r('app.color.input_stroke') })
    .shadow({ radius: 8, color: '#1A000000', offsetX: 0, offsetY: 2 })
  }

  @Builder
  renderButton(nodeId: string) {
    Button(this.buttonLabelFor(nodeId))
      .height(44)
      .margin({ top: 8 })
      .backgroundColor($r('app.color.send_button'))
      .fontColor(Color.White)
  }

  private buttonLabelFor(nodeId: string): string {
    const component = this.findComponent(nodeId);
    if (component === null) {
      return 'Button';
    }
    return this.buttonLabel(component);
  }

  @Builder
  renderDivider() {
    Divider()
      .strokeWidth(1)
      .color($r('app.color.input_stroke'))
      .margin({ top: 8, bottom: 8 })
  }
}
