// SqlQueryDialog.ets —— 可视化 SQL 查询条件配置对话框（对应 Android ui.dialog.SqlQueryDialog）。
//
// 与 Android 同构：不要求手写 SQL，每条子句一行（连接词 + 字段 + 运算符 + 值），
// 「添加子句」增行、行尾 × 删行（仅剩一行时清空值而不删行），首行连接词固定 Where。
// 拼装规则逐条照搬（这些正是解决「手写语句命中不到」的关键）：
//  · 表名取图层文件主名（OGR 对 shp 的图层命名即文件主名），表名/字段名双引号包裹，内部双引号翻倍；
//  · 值为纯数字时按数值输出（不加引号，保证 >/</>= 按数值而非字典序比较）；
//  · 「包含」译为 LIKE '%值%'，字符串值单引号包裹并转义内部单引号；
//  · 任一子句字段或值为空视为无效（提示「条件不完整」而不是执行一条必然落空的语句）。

import { Theme } from '../common/Theme';
import { Ui } from '../common/Ui';

/** 运算符显示名与 SQL 记号一一对应（顺序即下拉顺序，与 Android R.array.sql_operators 同） */
const OPERATOR_LABELS: string[] = ['等于', '不等于', '大于', '大于等于', '小于', '小于等于', '包含'];
const OPERATOR_TOKENS: string[] = ['=', '<>', '>', '>=', '<', '<=', 'LIKE'];
/** 非首行的连接词选项（Android R.array.sql_connectors） */
const CONNECTOR_LABELS: string[] = ['And', 'Or'];
/** 首行固定连接词 */
const WHERE_LABEL: string = 'Where';
/** 数值字面量判定（与 Kotlin String.toDoubleOrNull 可接受集对齐） */
const NUMBER_LITERAL: RegExp = /^[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?$/;

/** 一条子句（下标即行序，对象整体替换以驱动 Select 回显刷新） */
class Clause {
  /** 0 = And，1 = Or（首行不取此值，恒显示 Where） */
  connector: number = 0;
  fieldIndex: number = 0;
  opIndex: number = 0;
  value: string = '';
}

@CustomDialog
export struct SqlQueryDialog {
  controller: CustomDialogController;
  /** 标题里的图层名 */
  layerName: string = '';
  /** SQL 表名（图层文件主名） */
  tableName: string = '';
  /** 可选字段名清单（GDAL 读取失败时为空，此时不可应用） */
  fields: string[] = [];
  onExecuteSql: (sql: string) => void = (): void => {};
  onClearResult: () => void = (): void => {};

  @State clauses: Clause[] = [];

  aboutToAppear(): void {
    this.clauses = [new Clause()];
  }

  /** 子句对象不可观察，改后整体替换数组引用以驱动回显 */
  private refresh(): void {
    this.clauses = this.clauses.slice();
  }

  private addClause(): void {
    const list: Clause[] = this.clauses.slice();
    list.push(new Clause());
    this.clauses = list;
  }

  private removeClause(index: number): void {
    if (this.clauses.length > 1) {
      const list: Clause[] = this.clauses.slice();
      list.splice(index, 1);
      this.clauses = list;
      return;
    }
    // 至少保留一条：仅剩一条时清空值而不删行
    const only: Clause = this.clauses[0];
    only.value = '';
    this.refresh();
  }

  private connectorLabel(index: number): string {
    if (index === 0) {
      return WHERE_LABEL;
    }
    const c: Clause = this.clauses[index];
    return c.connector === 1 ? 'Or' : 'And';
  }

  private fieldLabel(c: Clause): string {
    return c.fieldIndex < this.fields.length ? this.fields[c.fieldIndex] : '选择字段';
  }

  private opLabel(c: Clause): string {
    return OPERATOR_LABELS[Math.min(c.opIndex, OPERATOR_LABELS.length - 1)];
  }

  private fieldOptions(): SelectOption[] {
    const options: SelectOption[] = [];
    for (let i = 0; i < this.fields.length; i++) {
      options.push({ value: this.fields[i] });
    }
    if (options.length === 0) {
      options.push({ value: '（无可用字段）' });
    }
    return options;
  }

  private opOptions(): SelectOption[] {
    const options: SelectOption[] = [];
    for (let i = 0; i < OPERATOR_LABELS.length; i++) {
      options.push({ value: OPERATOR_LABELS[i] });
    }
    return options;
  }

  private connectorOptions(): SelectOption[] {
    const options: SelectOption[] = [];
    for (let i = 0; i < CONNECTOR_LABELS.length; i++) {
      options.push({ value: CONNECTOR_LABELS[i] });
    }
    return options;
  }

  /** 标识符内双引号翻倍，避免破坏引号配对 */
  private static escapeIdentifier(name: string): string {
    return name.split('"').join('""');
  }

  /** 值的 SQL 字面量：LIKE 包 %%, 纯数字原样, 其余单引号包裹并转义 */
  private static valueLiteral(op: string, rawValue: string): string {
    if (op === 'LIKE') {
      return `'%${rawValue.split("'").join("''")}%'`;
    }
    // 对齐 Kotlin toDoubleOrNull：整数/小数/科学计数法均按数值字面量输出（不加引号）
    if (NUMBER_LITERAL.test(rawValue)) {
      return rawValue;
    }
    return `'${rawValue.split("'").join("''")}'`;
  }

  /** 拼装完整语句；条件不完整返回空串 */
  private buildSql(): string {
    if (this.clauses.length === 0 || this.fields.length === 0) {
      return '';
    }
    let where: string = '';
    for (let i = 0; i < this.clauses.length; i++) {
      const c: Clause = this.clauses[i];
      const field: string | undefined = this.fields[c.fieldIndex];
      if (field === undefined) {
        return '';
      }
      const rawValue: string = c.value.trim();
      if (rawValue.length === 0) {
        return '';
      }
      const op: string = OPERATOR_TOKENS[Math.min(c.opIndex, OPERATOR_TOKENS.length - 1)];
      if (i > 0) {
        where += c.connector === 1 ? ' OR ' : ' AND ';
      }
      where += `"${SqlQueryDialog.escapeIdentifier(field)}" ${op} ${SqlQueryDialog.valueLiteral(op, rawValue)}`;
    }
    return `SELECT * FROM "${SqlQueryDialog.escapeIdentifier(this.tableName)}" WHERE ${where}`;
  }

  private apply(): void {
    const sql: string = this.buildSql();
    if (sql.length === 0) {
      Ui.toast('请完整填写查询条件');
      return;
    }
    this.onExecuteSql(sql);
    this.controller.close();
  }

  private clear(): void {
    this.onClearResult();
    this.controller.close();
  }

  build() {
    Column() {
      Text(`SQL 查询${this.layerName.length > 0 ? `　${this.layerName}` : ''}`)
        .fontSize(Theme.FONT_TITLE)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.TEXT)
        .margin({ bottom: 10 })

      List({ space: 6 }) {
        ForEach(this.clauses, (c: Clause, index: number): void => {
          ListItem() {
            Column({ space: 4 }) {
              Row({ space: 6 }) {
                // 首行连接词固定 Where（不提供下拉，避免拼出 WHERE ... AND 之外的非法首句）
                Text(this.connectorLabel(index))
                  .fontSize(Theme.FONT)
                  .fontColor(index === 0 ? Theme.TEXT_HINT : Theme.PRIMARY_DARK)
                  .width(48)
                  .textAlign(TextAlign.Center)
                  .height(32)
                  .backgroundColor(Theme.SUBTLE)
                  .borderRadius(6)
                  .onClick((): void => {
                    if (index === 0) {
                      return;
                    }
                    c.connector = c.connector === 0 ? 1 : 0;
                    this.refresh();
                  })
                Select(this.fieldOptions())
                  .selected(c.fieldIndex)
                  .value(this.fieldLabel(c))
                  .layoutWeight(1)
                  .font({ size: Theme.FONT })
                  .backgroundColor(Theme.SUBTLE)
                  .onSelect((at: number): void => {
                    c.fieldIndex = at;
                    this.refresh();
                  })
                Select(this.opOptions())
                  .selected(c.opIndex)
                  .value(this.opLabel(c))
                  .font({ size: Theme.FONT })
                  .backgroundColor(Theme.SUBTLE)
                  .onSelect((at: number): void => {
                    c.opIndex = at;
                    this.refresh();
                  })
                SymbolGlyph($r('sys.symbol.xmark_circle'))
                  .fontSize(20)
                  .fontColor([Theme.TEXT_HINT])
                  .onClick((): void => {
                    this.removeClause(index);
                  })
              }
              .width('100%')

              TextInput({ text: c.value, placeholder: '值（数字按数值比较，文本自动加引号）' })
                .layoutWeight(1)
                .height(34)
                .fontSize(Theme.FONT)
                .backgroundColor(Theme.SUBTLE)
                .onChange((v: string): void => {
                  c.value = v;
                })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(8)
            .backgroundColor(Theme.BG)
            .borderRadius(8)
          }
          // 键不含 value：值由输入框自身承载，纳入键会在每次输入时重建而丢焦点
        }, (c: Clause, index: number): string =>
          `${index}:${c.connector}:${c.fieldIndex}:${c.opIndex}`)
      }
      .width('100%')
      .constraintSize({ maxHeight: 300 })
      .scrollBar(BarState.Auto)

      Text('应用后命中要素在地图上以洋红高亮，点击命中要素可查看其属性。')
        .fontSize(Theme.FONT_SUB)
        .fontColor(Theme.TEXT_HINT)
        .width('100%')
        .margin({ top: 8 })

      Row({ space: 8 }) {
        Button('添加子句')
          .height(36)
          .fontSize(Theme.FONT_SUB)
          .fontColor(Theme.PRIMARY_DARK)
          .backgroundColor(Theme.SUBTLE)
          .onClick((): void => {
            this.addClause();
          })
        Blank()
        Button('清除结果')
          .height(36)
          .fontSize(Theme.FONT_SUB)
          .fontColor(Theme.TEXT_SUB)
          .backgroundColor(Theme.SUBTLE)
          .onClick((): void => {
            this.clear();
          })
        Button('应用')
          .height(36)
          .fontSize(Theme.FONT)
          .fontColor(Theme.TEXT_ON_DARK)
          .backgroundColor(Theme.PRIMARY)
          .onClick((): void => {
            this.apply();
          })
      }
      .width('100%')
      .margin({ top: 12 })
    }
    .width('100%')
    .padding(Theme.PAD)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS)
  }
}
