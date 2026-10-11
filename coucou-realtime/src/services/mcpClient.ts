export interface McpToolDefinition {
  name: string;
  description: string;
  inputSchema: any;
}

export const mcpService = {
  async getAvailableTools(): Promise<McpToolDefinition[]> {
    return [
      {
        name: 'filesystem_read',
        description: 'Lê conteúdo de arquivos locais autorizados pelo usuário',
        inputSchema: { type: 'object', properties: { path: { type: 'string' } } },
      },
      {
        name: 'workspace_search',
        description: 'Pesquisa arquivos ou trechos de código na pasta ativa do projeto',
        inputSchema: { type: 'object', properties: { query: { type: 'string' } } },
      },
      {
        name: 'browser_search',
        description: 'Consulta informações e documentação online via navegador',
        inputSchema: { type: 'object', properties: { query: { type: 'string' } } },
      },
    ];
  },

  async callTool(name: string, args: any): Promise<any> {
    console.log(`[MCP Service] Chamando ferramenta: ${name}`, args);
    return {
      success: true,
      tool: name,
      output: `Resultado processado pelo conector MCP para: ${name}`,
    };
  },
};
